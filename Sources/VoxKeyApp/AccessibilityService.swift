@preconcurrency import AppKit
import ApplicationServices
import Foundation
import OSLog
import VoxKeyCore

struct DeliveryTiming {
    var focusResolutionTimeout: Duration = .milliseconds(250)
    var activationTimeout: Duration = .milliseconds(400)
    var modifierTimeout: Duration = .milliseconds(400)
    var directConfirmationTimeout: Duration = .milliseconds(250)
    var confirmationTimeout: Duration = .seconds(2)
    var foregroundConfirmationTimeout: Duration = .milliseconds(150)
    var pollInterval: Duration = .milliseconds(20)
}

@MainActor
final class AccessibilityService {
    private let logger = Logger(subsystem: "com.rodrigouroz.VoxKey", category: "delivery")
    private let client: any DesktopAccessibilityClient
    private let focusedElementResolver: FocusedElementResolver
    private let pasteboard: NSPasteboard
    private let timing: DeliveryTiming
    private let contextLimit = 256

    private struct IntentRecord {
        let element: AXUIElement
        let process: AccessibilityProcessIdentity
        let isWebBacked: Bool
        let snapshot: TextMutationSnapshot
    }

    private var intents: [DestinationToken: IntentRecord] = [:]
    private var directInsertionUnsupportedProcesses: Set<AccessibilityProcessIdentity> = []
    private var latestFocusSignalGeneration: UInt64 = 0
    private var delivering = false
    private var pendingPasteRestoration: Task<Void, Never>?
    private var shuttingDown = false

    init(
        client: any DesktopAccessibilityClient = SystemDesktopAccessibilityClient(),
        focusedElementResolver: FocusedElementResolver = FocusedElementResolver(),
        pasteboard: NSPasteboard = .general,
        timing: DeliveryTiming = DeliveryTiming()
    ) {
        self.client = client
        self.focusedElementResolver = focusedElementResolver
        self.pasteboard = pasteboard
        self.timing = timing
    }

    nonisolated static var isTrusted: Bool { AXIsProcessTrusted() }
    nonisolated static func requestTrust() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    func observeCurrentFocus(generation: UInt64) async {
        guard generation >= latestFocusSignalGeneration else { return }
        latestFocusSignalGeneration = generation
        guard client.trusted, !client.secureInputEnabled,
              let application = client.frontmostApplication else { return }
        await focusedElementResolver.refreshObservedFocus(
            in: AXUIElementCreateApplication(application.identity.processIdentifier),
            process: application.identity
        )
    }

    func captureCurrentDestination() async -> DestinationAssessment {
        let started = ContinuousClock.now
        guard !shuttingDown else { return rejected(.destinationUnavailable) }
        guard client.trusted else { return rejected(.permissionsUnavailable) }
        guard !client.secureInputEnabled else { return rejected(.secureDestination) }
        guard let application = client.frontmostApplication else { return rejected(.destinationUnavailable) }
        let label = DestinationLabel(applicationName: application.name, processIdentifier: application.identity.processIdentifier)
        let appElement = AXUIElementCreateApplication(application.identity.processIdentifier)
        var element = focusedElementResolver.resolve(in: appElement, process: application.identity)
        // The fast path never sleeps. On cold accessibility trees, wait for
        // focus to become observable while keeping the original app identity.
        while element == nil, started.duration(to: .now) < timing.focusResolutionTimeout {
            guard !Task.isCancelled else { return rejected(.destinationUnavailable, label: label) }
            try? await Task.sleep(for: timing.pollInterval)
            guard client.trusted else { return rejected(.permissionsUnavailable, label: label) }
            guard !client.secureInputEnabled else { return rejected(.secureDestination, label: label) }
            guard client.frontmostApplication?.identity == application.identity else {
                return rejected(.destinationChanged, label: label)
            }
            element = focusedElementResolver.resolve(in: appElement, process: application.identity)
        }
        guard let element else { return rejected(.focusUnavailable, label: label) }
        guard !isSecure(element) else { return rejected(.secureDestination, label: label) }
        guard isEditable(element) else { return rejected(.unsupportedInsertion, label: label) }
        guard let snapshot = mutationSnapshot(for: element) else { return rejected(.selectionUnavailable, label: label) }
        guard !Task.isCancelled, client.frontmostApplication?.identity == application.identity else {
            return rejected(.destinationChanged, label: label)
        }
        guard client.trusted else { return rejected(.permissionsUnavailable, label: label) }
        guard !client.secureInputEnabled, !isSecure(element) else { return rejected(.secureDestination, label: label) }
        let token = DestinationToken()
        intents[token] = IntentRecord(
            element: element, process: application.identity, isWebBacked: isWebBacked(element), snapshot: snapshot
        )
        logger.info("destination captured token=\(token.rawValue.uuidString, privacy: .public) elapsed_ms=\(self.milliseconds(since: started), privacy: .public)")
        return DestinationAssessment(kind: .editable, token: token, label: label)
    }

    func deliver(_ text: String, to token: DestinationToken, activateDestination: Bool = false) async -> DeliveryOutcome {
        guard !shuttingDown else { return .failed(.destinationUnavailable) }
        guard let intent = intents.removeValue(forKey: token) else { return .failed(.destinationUnavailable) }
        guard !delivering else { return .failed(.inputBusy) }
        delivering = true
        defer { delivering = false }
        let started = ContinuousClock.now
        let outcome = await deliver(text, intent: intent, activate: activateDestination)
        logger.notice("delivery completed token=\(token.rawValue.uuidString, privacy: .public) outcome=\(String(describing: outcome), privacy: .public) elapsed_ms=\(self.milliseconds(since: started), privacy: .public)")
        return outcome
    }

    private func deliver(_ text: String, intent: IntentRecord, activate: Bool) async -> DeliveryOutcome {
        if activate {
            guard client.application(processIdentifier: intent.process.processIdentifier)?.identity == intent.process else {
                return .failed(.destinationUnavailable)
            }
            client.activate(processIdentifier: intent.process.processIdentifier)
            let deadline = ContinuousClock.now.advanced(by: timing.activationTimeout)
            while client.frontmostApplication?.identity != intent.process, ContinuousClock.now < deadline {
                guard !Task.isCancelled else { return .failed(.destinationUnavailable) }
                try? await Task.sleep(for: timing.pollInterval)
            }
        }
        if let failure = validate(intent) { return .failed(failure) }
        let prepared: String
        if let preceding = intent.snapshot.preceding, let following = intent.snapshot.following {
            prepared = DictationMechanics.prepare(
                transcript: text, precedingText: preceding, followingText: following,
                replacesSelection: intent.snapshot.length > 0,
                selectedText: intent.snapshot.selectedPrefix.flatMap {
                    $0.utf16.count == intent.snapshot.length ? $0 : nil
                }
            )
        } else {
            // Unknown context is not the beginning/end of a document.
            prepared = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !prepared.isEmpty else { return .failed(.unsupportedInsertion) }
        let settable = client.isSettable(intent.element, kAXSelectedTextAttribute)
        let route = DeliveryRoutePolicy.preferredRoute(
            isWebBacked: intent.isWebBacked, directInsertionSettable: settable && (client.attribute(intent.element, kAXRoleAttribute) as? String) == "AXTextField",
            directInsertionKnownUnsupported: directInsertionUnsupportedProcesses.contains(intent.process)
        )
        if route == .accessibilitySelection {
            if let failure = validate(intent) { return .failed(failure) }
            let result = client.setAttribute(intent.element, kAXSelectedTextAttribute, prepared as CFString)
            // A messaging timeout does not prove the write was rejected. Never
            // issue a second write after a possibly applied request.
            if result == .success || result == .cannotComplete || result == .failure {
                let confirmation = await confirmInsertion(intent: intent, text: prepared, timeout: timing.directConfirmationTimeout)
                // An accepted request may apply after its metadata catches up.
                // Never dispatch a fallback based on a timed observation.
                return confirmation == .verified ? .delivered : .unconfirmed
            } else if result != .attributeUnsupported && result != .notImplemented {
                return .failed(.unsupportedInsertion)
            } else {
                directInsertionUnsupportedProcesses.insert(intent.process)
            }
        }
        return await paste(prepared, intent: intent)
    }

    func discard(_ token: DestinationToken?) {
        guard let token else { return }
        intents.removeValue(forKey: token)
    }

    func waitForPendingPaste() async {
        await pendingPasteRestoration?.value
    }

    func shutDown() async {
        shuttingDown = true
        intents.removeAll()
        while delivering { try? await Task.sleep(for: timing.pollInterval) }
        await waitForPendingPaste()
    }

    private func paste(_ text: String, intent: IntentRecord) async -> DeliveryOutcome {
        // Clipboard transactions stay serialized even after the UI is ready.
        await waitForPendingPaste()
        let deadline = ContinuousClock.now.advanced(by: timing.modifierTimeout)
        while client.modifiersPressed, ContinuousClock.now < deadline {
            guard !Task.isCancelled else { return .failed(.destinationUnavailable) }
            try? await Task.sleep(for: timing.pollInterval)
        }
        guard !client.modifiersPressed else { return .failed(.inputBusy) }
        if let failure = validate(intent) { return .failed(failure) }
        guard let lease = PasteboardLease.begin(text: text, pasteboard: pasteboard) else { return .failed(.pasteboardChanged) }
        // Snapshotting promised clipboard data can involve another process.
        // Check focus and ownership again after acquiring the lease.
        if let failure = validate(intent) {
            lease.restoreIfOwned()
            return .failed(failure)
        }
        guard lease.isOwned else { return .failed(.pasteboardChanged) }
        guard client.postPaste(processIdentifier: intent.process.processIdentifier) else {
            lease.restoreIfOwned()
            return .failed(.unsupportedInsertion)
        }
        let restorationDeadline = ContinuousClock.now.advanced(by: timing.confirmationTimeout)
        let confirmation = await confirmInsertion(
            intent: intent, text: text,
            timeout: min(timing.foregroundConfirmationTimeout, timing.confirmationTimeout)
        )
        if confirmation != .unavailable || !lease.isOwned || ContinuousClock.now >= restorationDeadline {
            // Positive text evidence proves the target has the transcript even
            // when surrounding AX context cannot establish full verification.
            restore(lease)
        } else {
            // Observation is inconclusive, not a failed write. Keep the clipboard
            // lease alive within its original budget without blocking dictation UI.
            pendingPasteRestoration = Task { [weak self] in
                defer { lease.restoreIfOwned() }
                guard let self, lease.isOwned, ContinuousClock.now < restorationDeadline else { return }
                _ = await confirmInsertion(
                    intent: intent, text: text, timeout: ContinuousClock.now.duration(to: restorationDeadline)
                )
            }
        }
        return confirmation == .verified ? .delivered : .unconfirmed
    }

    private func restore(_ lease: PasteboardLease) {
        if lease.restoreIfOwned() == .failed { logger.fault("pasteboard restoration failed") }
    }

    private enum InsertionObservation { case verified, textObserved, unavailable }

    private func validate(_ intent: IntentRecord) -> DeliveryFailure? {
        guard !Task.isCancelled, !shuttingDown else { return .destinationUnavailable }
        guard client.trusted else { return .permissionsUnavailable }
        guard !client.secureInputEnabled else { return .secureDestination }
        guard client.frontmostApplication?.identity == intent.process else { return .destinationChanged }
        guard let element = focusedElementResolver.resolve(
            in: AXUIElementCreateApplication(intent.process.processIdentifier), process: intent.process
        ) else { return .focusUnavailable }
        guard CFEqual(element, intent.element) else { return .destinationChanged }
        guard !isSecure(element) else { return .secureDestination }
        guard isEditable(element), let current = mutationSnapshot(for: element) else { return .selectionUnavailable }
        guard current.matchesIntent(intent.snapshot) else { return .editingConflict }
        return nil
    }

    private func confirmInsertion(intent: IntentRecord, text: String, timeout: Duration) async -> InsertionObservation {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var current: TextMutationSnapshot?
        var rangeReadback = InsertedTextReadback.notAttempted
        var observedEvidence: Set<String> = []
        repeat {
            guard client.trusted, !client.secureInputEnabled, !isSecure(intent.element),
                  client.frontmostApplication?.identity == intent.process else {
                logger.notice("confirmation interrupted reason=permissions_security_or_frontmost_changed")
                return .unavailable
            }
            // Editors can publish text before their caret/selection metadata.
            // Verify against the captured position while the draft is present,
            // rather than waiting for the caret and missing a quick user submit.
            if anchoredContextMatches(intent: intent, text: text, deadline: deadline) {
                rangeReadback = insertedTextReadback(text, intent: intent, deadline: deadline)
                if rangeReadback == .matched {
                    logger.info("insertion confirmed source=anchored_text")
                    return .verified
                }
            }
            current = mutationSnapshot(for: intent.element)
            let evidence = TextMutationVerification.evidence(
                original: intent.snapshot, current: current, insertedText: text,
                contextLimit: contextLimit
            )
            observedEvidence.insert(evidence.rawValue)
            if evidence.result == .confirmed {
                // Check the entire inserted range in bounded reads, not merely
                // the last 256 characters or the caret. No document-wide AXValue.
                rangeReadback = insertedTextReadback(text, intent: intent, deadline: deadline)
                if rangeReadback == .matched {
                    logger.info("insertion confirmed source=\(evidence.rawValue, privacy: .public)")
                    return .verified
                }
            }
            if let current, let originalCount = intent.snapshot.characterCount,
               let currentCount = current.characterCount, originalCount != currentCount,
               current.location == intent.snapshot.location + text.utf16.count,
               current.length == 0, current != intent.snapshot {
                rangeReadback = insertedTextReadback(text, intent: intent, deadline: deadline)
                if rangeReadback == .matched {
                    logger.info("insertion observed verification=\(evidence.rawValue, privacy: .public)")
                    return .textObserved
                }
            }
            guard !Task.isCancelled, ContinuousClock.now < deadline else { break }
            try? await Task.sleep(for: timing.pollInterval)
        } while true
        let evidence = TextMutationVerification.evidence(
            original: intent.snapshot, current: current, insertedText: text,
            contextLimit: contextLimit
        )
        if rangeReadback != .matched, client.trusted, !client.secureInputEnabled, !isSecure(intent.element),
           client.frontmostApplication?.identity == intent.process {
            // One bounded diagnostic read after an unconfirmed write tells us
            // whether text is present even when caret/context metadata disagrees.
            // This evidence does not relax confirmation or authorize another paste.
            rangeReadback = insertedTextReadback(text, intent: intent, deadline: .now.advanced(by: .milliseconds(100)))
        }
        // No text, hashes, or AX field values are logged. These facts distinguish
        // stale selection, unavailable reads, and actual context contradictions.
        let expectedLocation = intent.snapshot.location + text.utf16.count
        let caretMatches = current.map { $0.location == expectedLocation && $0.length == 0 } ?? false
        let followingIsLineBreakOnly = current?.following.map { $0 == "\n" || $0 == "\r\n" } ?? false
        logger.notice("confirmation incomplete observed_evidence=\(observedEvidence.sorted().joined(separator: ","), privacy: .public) evidence=\(evidence.rawValue, privacy: .public) range_readback=\(rangeReadback.rawValue, privacy: .public) caret_matches=\(caretMatches, privacy: .public) original_before_readable=\(intent.snapshot.preceding != nil, privacy: .public) original_after_readable=\(intent.snapshot.following != nil, privacy: .public) current_before_readable=\(current?.preceding != nil, privacy: .public) current_after_readable=\(current?.following != nil, privacy: .public) original_after_empty=\(intent.snapshot.following == "", privacy: .public) current_after_empty=\(current?.following == "", privacy: .public) current_after_line_break_only=\(followingIsLineBreakOnly, privacy: .public) web_backed=\(intent.isWebBacked, privacy: .public)")
        return .unavailable
    }

    private func anchoredContextMatches(intent: IntentRecord, text: String, deadline: ContinuousClock.Instant) -> Bool {
        let original = intent.snapshot
        guard ContinuousClock.now < deadline,
              let originalCount = original.characterCount,
              originalCount >= original.location + original.length,
              let preceding = original.preceding, let following = original.following else { return false }
        let (expectedCount, overflow) = (originalCount - original.length).addingReportingOverflow(text.utf16.count)
        guard !overflow,
              let currentCount: NSNumber = copyAttribute(intent.element, kAXNumberOfCharactersAttribute),
              currentCount.intValue == expectedCount else { return false }
        // An empty following read alone cannot prove the document ends there.
        // The expected total length also rejects incomplete selection replacement
        // and an unchanged matching substring when additional text was expected.
        let precedingLength = min(contextLimit, original.location)
        guard ContinuousClock.now < deadline,
              client.string(intent.element, range: CFRange(
                location: original.location - precedingLength, length: precedingLength
              )) == preceding else { return false }
        guard ContinuousClock.now < deadline,
              client.string(intent.element, range: CFRange(
                location: original.location + text.utf16.count,
                length: min(contextLimit, originalCount - original.location - original.length)
              )) == following else { return false }
        return true
    }

    private enum InsertedTextReadback: String {
        case notAttempted, matched, different, unavailable, interrupted
    }

    private func insertedTextReadback(_ text: String, intent: IntentRecord, deadline: ContinuousClock.Instant) -> InsertedTextReadback {
        let expected = text as NSString
        var offset = 0
        while offset < expected.length {
            guard !Task.isCancelled, ContinuousClock.now < deadline,
                  client.trusted, !client.secureInputEnabled else { return .interrupted }
            var count = min(contextLimit, expected.length - offset)
            // NSString range reads can replace an isolated surrogate with U+FFFD.
            // Splitting a pair would make two different emoji compare equal.
            if offset + count < expected.length,
               (0xD800...0xDBFF).contains(expected.character(at: offset + count - 1)) {
                count -= 1
            }
            guard let actual = client.string(intent.element, range: CFRange(location: intent.snapshot.location + offset, length: count)) else {
                return .unavailable
            }
            guard actual == expected.substring(with: NSRange(location: offset, length: count)) else { return .different }
            offset += count
        }
        return .matched
    }

    private func mutationSnapshot(for element: AXUIElement) -> TextMutationSnapshot? {
        guard let range = selectedTextRange(element) else { return nil }
        let precedingLength = min(contextLimit, range.location)
        let preceding = client.string(element, range: CFRange(location: range.location - precedingLength, length: precedingLength))
        let followingStart = range.location + range.length
        let characterCount: NSNumber? = copyAttribute(element, kAXNumberOfCharactersAttribute)
        let followingLength = characterCount.map { max(0, min(contextLimit, $0.intValue - followingStart)) }
        let following = followingLength.flatMap { client.string(element, range: CFRange(location: followingStart, length: $0)) }
        let selectionLength = min(contextLimit, range.length)
        return TextMutationSnapshot(
            range: range, preceding: preceding, following: following,
            selectedPrefix: client.string(element, range: CFRange(location: range.location, length: selectionLength)),
            selectedSuffix: client.string(element, range: CFRange(location: followingStart - selectionLength, length: selectionLength)),
            characterCount: characterCount?.intValue
        )
    }

    private func isSecure(_ element: AXUIElement) -> Bool {
        let role: String? = copyAttribute(element, kAXRoleAttribute)
        let subrole: String? = copyAttribute(element, kAXSubroleAttribute)
        return role == "AXSecureTextField" || subrole == kAXSecureTextFieldSubrole
    }
    private func isEditable(_ element: AXUIElement) -> Bool {
        DestinationCapabilityClassifier.isEditable(
            role: copyAttribute(element, kAXRoleAttribute),
            editable: (copyAttribute(element, "AXEditable") as NSNumber?)?.boolValue,
            enabled: (copyAttribute(element, kAXEnabledAttribute) as NSNumber?)?.boolValue,
            hasSelection: selectedTextRange(element) != nil,
            directInsertionSettable: client.isSettable(element, kAXSelectedTextAttribute)
                || client.isSettable(element, kAXValueAttribute)
        )
    }
    private func isWebBacked(_ element: AXUIElement) -> Bool {
        if DestinationCapabilityClassifier.isWebBacked(role: nil, attributeNames: client.attributeNames(element)) { return true }
        var current: AXUIElement? = element
        for _ in 0..<12 {
            guard let candidate = current else { return false }
            let role: String? = copyAttribute(candidate, kAXRoleAttribute)
            if role == "AXWebArea" { return true }
            guard let parent: AXUIElement = copyAttribute(candidate, kAXParentAttribute), !CFEqual(parent, candidate) else { return false }
            current = parent
        }
        return false
    }
    private func selectedTextRange(_ element: AXUIElement) -> CFRange? {
        guard let value: AXValue = copyAttribute(element, kAXSelectedTextRangeAttribute),
              AXValueGetType(value) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range), range.location >= 0, range.length >= 0,
              range.location <= Int.max - range.length else { return nil }
        return range
    }
    private func copyAttribute<T>(_ element: AXUIElement, _ name: String) -> T? { client.attribute(element, name) as? T }
    private func rejected(_ failure: DeliveryFailure, label: DestinationLabel? = nil) -> DestinationAssessment {
        logger.notice("destination rejected reason=\(String(describing: failure), privacy: .public)")
        return DestinationAssessment(kind: failure == .secureDestination ? .secure : .unknown, token: nil, label: label, failure: failure)
    }
    private func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let duration = start.duration(to: .now).components
        return Int(duration.seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000)
    }
}
