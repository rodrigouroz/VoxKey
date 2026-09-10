import AppKit
import ApplicationServices
import Testing
@testable import VoxKeyApp
import VoxKeyCore

@MainActor
@Test(arguments: [false, true])
func dictatedWordReplacementFitsTheExistingSentence(web: Bool) async throws {
    let fixture = DesktopFixture(web: web)
    fixture.editor.string = "This is my first test"
    fixture.editor.setSelectedRange(NSRange(location: 11, length: 5))
    let token = try #require(await fixture.service.captureCurrentDestination().token)

    #expect(await fixture.service.deliver("Second.", to: token) == .delivered)
    #expect(fixture.editor.string == "This is my second test")
    #expect(fixture.editor.selectedRange() == NSRange(location: 17, length: 0))
    #expect(fixture.pasteboard.string(forType: .string) == "original clipboard")
}

@MainActor
@Test
func nativeDeliveryInsertsOnceAndKeepsTheClipboard() async throws {
    let fixture = DesktopFixture()
    fixture.editor.string = "Before after"
    fixture.editor.setSelectedRange(NSRange(location: 6, length: 0))
    let token = try #require(await fixture.service.captureCurrentDestination().token)
    #expect(await fixture.service.deliver("words", to: token) == .delivered)
    #expect(fixture.editor.string == "Before words after")
    #expect(fixture.pasteboard.string(forType: .string) == "original clipboard")
    #expect(fixture.pasteCount == 0)
}

@MainActor
@Test
func coldFocusCanBecomeAvailableBeforeCaptureTimesOut() async throws {
    let fixture = DesktopFixture()
    fixture.focusAvailable = false
    fixture.focusReadyAt = .now.advanced(by: .milliseconds(40))
    let token = try #require(await fixture.service.captureCurrentDestination().token)
    #expect(await fixture.service.deliver("Hello", to: token) == .delivered)
    #expect(fixture.editor.string == "Hello")
}

@MainActor
@Test(arguments: [false, true])
func pasteWaitsForModifiersOrPreservesTextWithoutDispatch(release: Bool) async throws {
    let fixture = DesktopFixture(web: true)
    fixture.modifiersPressed = true
    fixture.timing.modifierTimeout = .milliseconds(80)
    let token = try #require(await fixture.service.captureCurrentDestination().token)
    // OS keyboard state changes independently of the app's busy main actor.
    if release { fixture.modifierReleaseAt = .now.advanced(by: .milliseconds(20)) }
    let expected: DeliveryOutcome = release ? .delivered : .failed(.inputBusy)
    #expect(await fixture.service.deliver("Hello", to: token) == expected)
    #expect(fixture.editor.string == (release ? "Hello" : ""))
    #expect(fixture.pasteboard.string(forType: .string) == "original clipboard")
}

@MainActor
@Test
func keyboardEditableWebFieldUsesPasteWithoutDirectAXWrite() async throws {
    let fixture = DesktopFixture(web: true)
    let token = try #require(await fixture.service.captureCurrentDestination().token)
    #expect(await fixture.service.deliver("Hello", to: token) == .delivered)
    #expect(fixture.editor.string == "Hello")
    #expect(fixture.pasteboard.string(forType: .string) == "original clipboard")
    #expect(fixture.directWriteCount == 0)
}

@MainActor
@Test
func delayedPasteKeepsTheLeaseUntilTheEditorConsumesIt() async throws {
    let fixture = DesktopFixture(web: true)
    fixture.pasteDelay = .milliseconds(350)
    fixture.timing.confirmationTimeout = .seconds(1)
    fixture.timing.foregroundConfirmationTimeout = .seconds(1)
    let token = try #require(await fixture.service.captureCurrentDestination().token)
    #expect(await fixture.service.deliver("Hello", to: token) == .delivered)
    #expect(fixture.editor.string == "Hello")
    #expect(fixture.pasteboard.string(forType: .string) == "original clipboard")
    #expect(fixture.pasteCount == 1)
}

@MainActor
@Test
func directNoOpCannotPasteIntoAChangedField() async throws {
    let fixture = DesktopFixture()
    fixture.directBehavior = .moveFocusWithoutWriting
    let token = try #require(await fixture.service.captureCurrentDestination().token)
    #expect(await fixture.service.deliver("Hello", to: token) == .unconfirmed)
    #expect(fixture.editor.string.isEmpty)
    #expect(fixture.otherEditor.string.isEmpty)
    #expect(fixture.pasteCount == 0)
}

@MainActor
@Test
func explicitlyUnsupportedDirectWriteUsesPasteAndRemembersThatRoute() async throws {
    let fixture = DesktopFixture()
    fixture.directBehavior = .unsupported
    for _ in 0..<2 {
        let token = try #require(await fixture.service.captureCurrentDestination().token)
        #expect(await fixture.service.deliver("Hello", to: token) == .delivered)
    }
    #expect(fixture.editor.string == "Hello Hello")
    #expect(fixture.directWriteCount == 1)
    #expect(fixture.pasteboard.string(forType: .string) == "original clipboard")
}

@MainActor
@Test
func timeoutAfterApplyingDirectWriteDoesNotDuplicateText() async throws {
    let fixture = DesktopFixture()
    fixture.directBehavior = .writeThenTimeout
    let token = try #require(await fixture.service.captureCurrentDestination().token)
    #expect(await fixture.service.deliver("Hello", to: token) == .delivered)
    #expect(fixture.editor.string == "Hello")
    #expect(fixture.pasteCount == 0)
}

@MainActor
@Test
func staleAXMetadataCannotTriggerASecondInsertionAfterPositiveReadback() async throws {
    let fixture = DesktopFixture()
    fixture.frozenSelectedRange = NSRange(location: 0, length: 0)
    fixture.frozenCharacterCount = 0
    let token = try #require(await fixture.service.captureCurrentDestination().token)
    #expect(await fixture.service.deliver("Hello", to: token) == .unconfirmed)
    #expect(fixture.editor.string == "Hello")
    #expect(fixture.pasteCount == 0)
}

@MainActor
@Test(arguments: [false, true], [false, true])
func insertedTextIsConfirmedWithoutWaitingForTheCaret(web: Bool, selectionUnavailable: Bool) async throws {
    let fixture = DesktopFixture(web: web)
    fixture.editor.string = "Before old after"
    let selection = NSRange(location: 7, length: 3)
    fixture.editor.setSelectedRange(selection)
    fixture.frozenSelectedRange = selection
    fixture.selectionUnavailableAfterWrite = selectionUnavailable
    let token = try #require(await fixture.service.captureCurrentDestination().token)

    #expect(await fixture.service.deliver("new words", to: token) == .delivered)
    #expect(fixture.editor.string == "Before new words after")
    #expect(fixture.pasteCount == (web ? 1 : 0))
    #expect(fixture.pasteboard.string(forType: .string) == "original clipboard")
}

@MainActor
@Test(arguments: ["Altered new words after", "Before new words wrong", "Before new words after extra"])
func staleCaretCannotConfirmTextWithChangedSurroundings(document: String) async throws {
    let fixture = DesktopFixture(web: true)
    fixture.editor.string = "Before old after"
    fixture.editor.setSelectedRange(NSRange(location: 7, length: 3))
    fixture.frozenSelectedRange = fixture.editor.selectedRange()
    fixture.documentAfterPaste = document
    let token = try #require(await fixture.service.captureCurrentDestination().token)

    #expect(await fixture.service.deliver("new words", to: token) == .unconfirmed)
    #expect(fixture.editor.string == document)
    #expect(fixture.pasteCount == 1)
}

@MainActor
@Test
func emptyWebParagraphCanDropItsPlaceholderLineBreak() async throws {
    let fixture = DesktopFixture(web: true)
    fixture.editor.string = "\n"
    fixture.editor.setSelectedRange(NSRange(location: 0, length: 0))
    fixture.documentAfterPaste = "Hello"
    let token = try #require(await fixture.service.captureCurrentDestination().token)

    #expect(await fixture.service.deliver("Hello", to: token) == .unconfirmed)
    #expect(fixture.editor.string == "Hello")
    #expect(fixture.pasteCount == 1)
    #expect(fixture.pasteboard.string(forType: .string) == "original clipboard")
}

@MainActor
@Test(arguments: ["\n\n", " ", "existing text", "Before\n"])
func webInsertionCannotDiscardExistingContent(initial: String) async throws {
    let fixture = DesktopFixture(web: true)
    fixture.editor.string = initial
    fixture.editor.setSelectedRange(NSRange(location: 0, length: 0))
    fixture.documentAfterPaste = "Hello"
    let token = try #require(await fixture.service.captureCurrentDestination().token)

    #expect(await fixture.service.deliver("Hello", to: token) == .unconfirmed)
    #expect(fixture.pasteCount == 1)
}

@MainActor
@Test
func nativeInsertionCannotDiscardAnExistingLineBreak() async throws {
    let fixture = DesktopFixture()
    fixture.directBehavior = .unsupported
    fixture.editor.string = "\n"
    fixture.editor.setSelectedRange(NSRange(location: 0, length: 0))
    fixture.documentAfterPaste = "Hello"
    let token = try #require(await fixture.service.captureCurrentDestination().token)
    #expect(await fixture.service.deliver("Hello", to: token) == .unconfirmed)
}

@MainActor
@Test
func emptyWebParagraphStillRequiresTheEntireTranscription() async throws {
    let fixture = DesktopFixture(web: true)
    fixture.editor.string = "\n"
    fixture.editor.setSelectedRange(NSRange(location: 0, length: 0))
    let suffix = String(repeating: "a", count: 300)
    fixture.documentAfterPaste = "Wrong " + suffix
    let token = try #require(await fixture.service.captureCurrentDestination().token)
    #expect(await fixture.service.deliver("Hello " + suffix, to: token) == .unconfirmed)
    #expect(fixture.pasteCount == 1)
}

@MainActor
@Test
func contradictoryPastedTextIsPreservedAsUncertain() async throws {
    let fixture = DesktopFixture(web: true)
    fixture.pastedOverride = "World"
    let token = try #require(await fixture.service.captureCurrentDestination().token)
    #expect(await fixture.service.deliver("Hello", to: token) == .unconfirmed)
    #expect(fixture.editor.string == "World")
    #expect(fixture.pasteboard.string(forType: .string) == "original clipboard")
}

@MainActor
@Test
func longPasteVerifiesMoreThanItsSuffix() async throws {
    let fixture = DesktopFixture(web: true)
    let transcript = "Hello " + String(repeating: "a", count: 300)
    fixture.pastedOverride = "Wrong " + String(repeating: "a", count: 300)
    let token = try #require(await fixture.service.captureCurrentDestination().token)
    #expect(await fixture.service.deliver(transcript, to: token) == .unconfirmed)
    #expect(fixture.editor.string.hasPrefix("Wrong"))
}

@MainActor
@Test(arguments: [false, true])
func deliveryVerifiesEmojiAcrossBoundedUTF16Reads(web: Bool) async throws {
    let fixture = DesktopFixture(web: web)
    let transcript = "Hello " + String(repeating: "a", count: 249) + "👩🏽‍💻" + String(repeating: "é", count: 254) + "🌎"
    let token = try #require(await fixture.service.captureCurrentDestination().token)
    #expect(await fixture.service.deliver(transcript, to: token) == .delivered)
    #expect(fixture.editor.string == transcript)
}

@MainActor
@Test
func differentEmojiAtAChunkBoundaryCannotConfirmDelivery() async throws {
    let fixture = DesktopFixture(web: true)
    let prefix = "Hello " + String(repeating: "a", count: 249)
    let suffix = String(repeating: "b", count: 300)
    fixture.pastedOverride = prefix + "🙂" + suffix
    let token = try #require(await fixture.service.captureCurrentDestination().token)
    #expect(await fixture.service.deliver(prefix + "😀" + suffix, to: token) == .unconfirmed)
    #expect(fixture.editor.string == fixture.pastedOverride)
}

@MainActor
@Test
func selectionContentChangeBlocksReplacementEvenWhenRangeIsUnchanged() async throws {
    let fixture = DesktopFixture()
    fixture.editor.string = "Before hello after"
    fixture.editor.setSelectedRange(NSRange(location: 7, length: 5))
    let token = try #require(await fixture.service.captureCurrentDestination().token)
    fixture.editor.string = "Before world after"
    fixture.editor.setSelectedRange(NSRange(location: 7, length: 5))
    #expect(await fixture.service.deliver("replacement", to: token) == .failed(.editingConflict))
    #expect(fixture.editor.string == "Before world after")
}

@MainActor
@Test
func secureInputActivatedAfterCaptureBlocksAllDelivery() async throws {
    let fixture = DesktopFixture(web: true)
    let token = try #require(await fixture.service.captureCurrentDestination().token)
    fixture.secureInputEnabled = true
    #expect(await fixture.service.deliver("Hello", to: token) == .failed(.secureDestination))
    #expect(fixture.editor.string.isEmpty)
    #expect(fixture.pasteboard.string(forType: .string) == "original clipboard")
}

@MainActor
@Test
func newerClipboardSurvivesAnUnconfirmedPaste() async throws {
    let fixture = DesktopFixture(web: true)
    fixture.changeClipboardInsteadOfPasting = true
    let token = try #require(await fixture.service.captureCurrentDestination().token)
    #expect(await fixture.service.deliver("Hello", to: token) == .unconfirmed)
    #expect(fixture.editor.string.isEmpty)
    #expect(fixture.pasteboard.string(forType: .string) == "new user copy")
}

/// Simulates only cross-process AX and keyboard dispatch. The delivery service,
/// resolver, AppKit text storage, and uniquely named pasteboard are real.
@MainActor
final class DesktopFixture: DesktopAccessibilityClient, FocusedElementClient {
    enum DirectBehavior { case write, writeThenTimeout, moveFocusWithoutWriting, noOp, unsupported, delayedWrite }
    let editor = NSTextView()
    let otherEditor = NSTextView()
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("VoxKey.delivery.tests.\(UUID())"))
    let element = AXUIElementCreateApplication(getpid())
    let otherElement = AXUIElementCreateSystemWide()
    let identity = AccessibilityProcessIdentity(processIdentifier: getpid(), launchDate: Date(timeIntervalSince1970: 1))
    let web: Bool
    var trusted = true
    var secureInputEnabled = false
    private var modifiersHeld = false
    var modifierReleaseAt: ContinuousClock.Instant?
    var modifiersPressed: Bool {
        get { modifiersHeld && !(modifierReleaseAt.map { ContinuousClock.now >= $0 } ?? false) }
        set { modifiersHeld = newValue }
    }
    var otherFocused = false
    var focusAvailable = true
    var focusReadyAt: ContinuousClock.Instant?
    private var canResolveFocus: Bool { focusAvailable || (focusReadyAt.map { ContinuousClock.now >= $0 } ?? false) }
    var role = "AXTextField"
    var directBehavior = DirectBehavior.write
    var frozenSelectedRange: NSRange?
    var frozenCharacterCount: Int?
    var selectionUnavailableAfterWrite = false
    var textUnavailableAfterWrite = false
    var pastedOverride: String?
    var documentAfterPaste: String?
    var pasteDelay: Duration = .zero
    var changeClipboardInsteadOfPasting = false
    private(set) var pasteCount = 0
    private(set) var directWriteCount = 0
    private var pendingPaste: Task<Void, Never>?
    private(set) var pendingDirectWrite: Task<Void, Never>?
    var timing: DeliveryTiming = {
        var value = DeliveryTiming()
        value.directConfirmationTimeout = .milliseconds(80)
        value.confirmationTimeout = .milliseconds(80)
        value.pollInterval = .milliseconds(5)
        return value
    }()
    lazy var service = AccessibilityService(
        client: self, focusedElementResolver: FocusedElementResolver(client: self), pasteboard: pasteboard, timing: timing
    )

    init(web: Bool = false) {
        _ = NSApplication.shared
        self.web = web
        editor.string = ""
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        pasteboard.setString("original clipboard", forType: .string)
    }
    isolated deinit {
        pendingPaste?.cancel()
        pasteboard.releaseGlobally()
    }
    var frontmostApplication: DestinationApplication? { DestinationApplication(identity: identity, name: "Fixture") }
    func application(processIdentifier: pid_t) -> DestinationApplication? { frontmostApplication }
    func activate(processIdentifier: pid_t) {}
    func focusedElement(in application: AXUIElement) -> AXUIElement? { canResolveFocus ? (otherFocused ? otherElement : element) : nil }
    func systemWideFocusedElement() -> AXUIElement? { nil }
    func processIdentifier(of element: AXUIElement) -> pid_t? { getpid() }
    func isFocused(_ element: AXUIElement) -> Bool { canResolveFocus && CFEqual(element, otherFocused ? otherElement : self.element) }
    func enable(_ attribute: String, in application: AXUIElement) -> AXError { .attributeUnsupported }
    func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        let view = CFEqual(element, self.element) ? editor : otherEditor
        switch name {
        case kAXRoleAttribute: return (web ? "AXTextArea" : role) as CFString
        case kAXEnabledAttribute: return kCFBooleanTrue
        case kAXNumberOfCharactersAttribute: return NSNumber(value: frozenCharacterCount ?? (view.string as NSString).length)
        case kAXSelectedTextRangeAttribute:
            if selectionUnavailableAfterWrite && (directWriteCount > 0 || pasteCount > 0) { return nil }
            let selected = frozenSelectedRange ?? view.selectedRange()
            var range = CFRange(location: selected.location, length: selected.length)
            return AXValueCreate(.cfRange, &range)
        default: return nil
        }
    }
    func attributeNames(_ element: AXUIElement) -> Set<String> { web ? ["AXDOMIdentifier"] : [] }
    func isSettable(_ element: AXUIElement, _ name: String) -> Bool { !web }
    func setAttribute(_ element: AXUIElement, _ name: String, _ value: CFTypeRef) -> AXError {
        directWriteCount += 1
        if directBehavior == .unsupported { return .attributeUnsupported }
        if directBehavior == .delayedWrite {
            let text = value as! String
            let selection = editor.selectedRange()
            pendingDirectWrite = Task {
                try? await Task.sleep(for: .milliseconds(200))
                editor.insertText(text, replacementRange: selection)
            }
            return .success
        }
        if directBehavior == .noOp { return .success }
        if directBehavior == .moveFocusWithoutWriting {
            otherFocused = true
            return .success
        }
        editor.insertText(value as! String, replacementRange: editor.selectedRange())
        return directBehavior == .writeThenTimeout ? .cannotComplete : .success
    }
    func string(_ element: AXUIElement, range: CFRange) -> String? {
        if textUnavailableAfterWrite && range.length > 0 && (directWriteCount > 0 || pasteCount > 0) { return nil }
        let value = (CFEqual(element, self.element) ? editor.string : otherEditor.string) as NSString
        guard range.location >= 0, range.length >= 0, range.location + range.length <= value.length else { return nil }
        return value.substring(with: NSRange(location: range.location, length: range.length))
    }
    func postPaste(processIdentifier: pid_t) -> Bool {
        pasteCount += 1
        if changeClipboardInsteadOfPasting {
            pasteboard.clearContents()
            pasteboard.setString("new user copy", forType: .string)
        } else if pasteDelay == .zero {
            applyPaste()
        } else {
            pendingPaste = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: pasteDelay)
                guard !Task.isCancelled else { return }
                applyPaste()
            }
        }
        return true
    }
    private func applyPaste() {
        let view = otherFocused ? otherEditor : editor
        let text = pastedOverride ?? pasteboard.string(forType: .string) ?? ""
        view.insertText(text, replacementRange: view.selectedRange())
        if let documentAfterPaste {
            let caret = min(view.selectedRange().location, documentAfterPaste.utf16.count)
            view.string = documentAfterPaste
            view.setSelectedRange(NSRange(location: caret, length: 0))
        }
    }
}

@MainActor
@Test
func nativeMultilineUsesTheEditorPasteCommandEvenWhenAXClaimsWritable() async throws {
    let fixture = DesktopFixture()
    fixture.role = "AXTextArea"
    fixture.directBehavior = .noOp
    let token = try #require(await fixture.service.captureCurrentDestination().token)
    let outcome = await fixture.service.deliver("Hello", to: token)
    await fixture.service.waitForPendingPaste()
    #expect(fixture.editor.string == "Hello")
    #expect(outcome == .delivered)
    #expect(fixture.directWriteCount == 0)
    #expect(fixture.pasteCount == 1)
}

@MainActor
@Test(arguments: [false, true])
func selectedBuildCorrectionPreservesSentenceCasingAndExistingPeriod(web: Bool) async throws {
    let fixture = DesktopFixture(web: web)
    let original = "Okay, let's check. This is the first dictation after this new filled."
    fixture.editor.string = original
    fixture.editor.setSelectedRange((original as NSString).range(of: "filled"))
    let token = try #require(await fixture.service.captureCurrentDestination().token)
    #expect(await fixture.service.deliver("Build.", to: token) == .delivered)
    await fixture.service.waitForPendingPaste()
    #expect(fixture.editor.string == "Okay, let's check. This is the first dictation after this new build.")
}
