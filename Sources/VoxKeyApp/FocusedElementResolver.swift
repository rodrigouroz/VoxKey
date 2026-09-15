import ApplicationServices
import Foundation
#if DEBUG && VOXKEY_LOCAL_DIAGNOSTICS && !VOXKEY_RELEASE
import OSLog
#endif

struct AccessibilityProcessIdentity: Hashable {
    let processIdentifier: pid_t
    let launchDate: Date?
}

@MainActor
protocol FocusedElementClient: AnyObject {
    func prepare(_ application: AXUIElement)
    func focusedElement(in application: AXUIElement) -> AXUIElement?
    func systemWideFocusedElement() -> AXUIElement?
    func processIdentifier(of element: AXUIElement) -> pid_t?
    func isFocused(_ element: AXUIElement) -> Bool
    func enable(_ attribute: String, in application: AXUIElement) -> AXError
    func focusedWindow(in application: AXUIElement) -> AXUIElement?
    func role(of element: AXUIElement) -> String?
    func children(of element: AXUIElement, limit: Int) -> [AXUIElement]?
}

extension FocusedElementClient {
    func prepare(_ application: AXUIElement) {}
    func focusedWindow(in application: AXUIElement) -> AXUIElement? { nil }
    func role(of element: AXUIElement) -> String? { nil }
    func children(of element: AXUIElement, limit: Int) -> [AXUIElement]? { nil }
}

@MainActor
final class SystemFocusedElementClient: FocusedElementClient {
    func prepare(_ application: AXUIElement) {
        // Destination resolution is off the event-tap callback, but it still
        // gates capture feedback. Bound an unresponsive target app instead of
        // letting its Accessibility server stall VoxKey indefinitely.
        AXUIElementSetMessagingTimeout(application, 0.1)
    }

    func focusedElement(in application: AXUIElement) -> AXUIElement? {
        focusedElement(from: application)
    }

    func systemWideFocusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.1)
        return focusedElement(from: systemWide)
    }

    func processIdentifier(of element: AXUIElement) -> pid_t? {
        var processIdentifier = pid_t()
        guard AXUIElementGetPid(element, &processIdentifier) == .success else { return nil }
        return processIdentifier
    }

    func isFocused(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXFocusedAttribute as CFString,
            &value
        ) == .success else { return false }
        return (value as? NSNumber)?.boolValue == true
    }

    private func focusedElement(from element: AXUIElement) -> AXUIElement? {
        elementAttribute(kAXFocusedUIElementAttribute, from: element)
    }

    func focusedWindow(in application: AXUIElement) -> AXUIElement? {
        elementAttribute(kAXFocusedWindowAttribute, from: application)
    }

    private func elementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    func children(of element: AXUIElement, limit: Int) -> [AXUIElement]? {
        var values: CFArray?
        let result = AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, limit, &values)
        switch result {
        case .success: return values as? [AXUIElement]
        case .attributeUnsupported, .notImplemented, .noValue, .illegalArgument: return []
        default: return nil
        }
    }

    func enable(_ attribute: String, in application: AXUIElement) -> AXError {
        AXUIElementSetAttributeValue(application, attribute as CFString, kCFBooleanTrue)
    }
}

@MainActor
final class FocusedElementResolver {
    static let manualAccessibilityAttribute = "AXManualAccessibility"
    static let enhancedUserInterfaceAttribute = "AXEnhancedUserInterface"

    private let client: FocusedElementClient
    private let focusEvents: FocusEventSource
    #if DEBUG && VOXKEY_LOCAL_DIAGNOSTICS && !VOXKEY_RELEASE
    private let logger = Logger(subsystem: "com.rodrigouroz.VoxKey", category: "focus")
    #endif
    private struct Enablement {
        let result: AXError
        let attemptedAt: ContinuousClock.Instant
        var shouldRetry: Bool {
            switch result {
            case .success, .attributeUnsupported, .notImplemented: false
            default: attemptedAt.duration(to: .now) >= .milliseconds(250)
            }
        }
    }
    private var enablementByProcess: [AccessibilityProcessIdentity: [String: Enablement]] = [:]
    private var observedFocus: (process: AccessibilityProcessIdentity, element: AXUIElement, window: AXUIElement?)?
    private var pendingFocus: (application: AXUIElement, process: AccessibilityProcessIdentity)?
    private var focusRefreshTask: Task<Void, Never>?

    convenience init() {
        let client = SystemFocusedElementClient()
        self.init(client: client, focusEvents: SystemFocusEventSource())
    }

    init(
        client: FocusedElementClient,
        focusEvents: FocusEventSource = NoopFocusEventSource()
    ) {
        self.client = client
        self.focusEvents = focusEvents
        focusEvents.onFocusEvent = { [weak self] application, process in
            self?.recordFocusEvent(in: application, process: process)
        }
        focusEvents.start()
    }

    func resolve(
        in application: AXUIElement,
        process: AccessibilityProcessIdentity
    ) -> AXUIElement? {
        // A trigger resolves the current destination immediately and supersedes
        // any queued background signal, including one for the previous app.
        focusRefreshTask?.cancel()
        focusRefreshTask = nil
        pendingFocus = nil
        client.prepare(application)
        if let focused = matchingFocusedElement(in: application, process: process) {
            remember(focused, process: process)
            return focused
        }
        if let focused = matchingObservedElement(in: application, process: process) {
            return focused
        }

        if let focused = focusedElementAfterEnablingCapabilities(
            in: application,
            process: process
        ) {
            remember(focused, process: process)
            return focused
        }
        guard let match = focusedEditorInWindow(of: application) else { return nil }
        remember(match.element, process: process, window: match.window)
        #if DEBUG && VOXKEY_LOCAL_DIAGNOSTICS && !VOXKEY_RELEASE
        logger.notice("focus resolved route=focused_window pid=\(process.processIdentifier, privacy: .public)")
        #endif
        return match.element
    }

    func refreshObservedFocus(
        in application: AXUIElement,
        process: AccessibilityProcessIdentity
    ) async {
        recordFocusEvent(in: application, process: process)
        await waitForPendingFocus()
    }

    func waitForPendingFocus() async { await focusRefreshTask?.value }

    private func focusedElementAfterEnablingCapabilities(
        in application: AXUIElement,
        process: AccessibilityProcessIdentity
    ) -> AXUIElement? {

        removeStaleLaunches(for: process)
        let manual = enablementByProcess[process]?[Self.manualAccessibilityAttribute]
        if manual == nil || manual?.shouldRetry == true {
            let result = client.enable(Self.manualAccessibilityAttribute, in: application)
            #if DEBUG && VOXKEY_LOCAL_DIAGNOSTICS && !VOXKEY_RELEASE
            logger.notice(
                "focus retry capability=manual_accessibility pid=\(process.processIdentifier, privacy: .public) ax_error=\(result.rawValue, privacy: .public)"
            )
            #endif
            enablementByProcess[process, default: [:]][Self.manualAccessibilityAttribute] =
                Enablement(result: result, attemptedAt: .now)
            if let focused = matchingFocusedElement(in: application, process: process) {
                return focused
            }
        }

        let enhanced = enablementByProcess[process]?[Self.enhancedUserInterfaceAttribute]
        if enhanced == nil || enhanced?.shouldRetry == true {
            let result = client.enable(Self.enhancedUserInterfaceAttribute, in: application)
            #if DEBUG && VOXKEY_LOCAL_DIAGNOSTICS && !VOXKEY_RELEASE
            logger.notice(
                "focus retry capability=enhanced_user_interface pid=\(process.processIdentifier, privacy: .public) ax_error=\(result.rawValue, privacy: .public)"
            )
            #endif
            enablementByProcess[process, default: [:]][Self.enhancedUserInterfaceAttribute] =
                Enablement(result: result, attemptedAt: .now)
            if let focused = matchingFocusedElement(in: application, process: process) {
                return focused
            }
        }

        return nil
    }

    private func recordFocusEvent(
        in application: AXUIElement,
        process: AccessibilityProcessIdentity
    ) {
        observedFocus = nil
        pendingFocus = (application, process)
        guard focusRefreshTask == nil else { return }
        // AX notifications and global input signals share one bounded window.
        // Keep the newest signal without extending the wait during an event burst.
        focusRefreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(30)) } catch { return }
            guard let self, let pending = pendingFocus else { return }
            focusRefreshTask = nil
            pendingFocus = nil
            _ = resolve(in: pending.application, process: pending.process)
        }
    }

    private func remember(_ element: AXUIElement, process: AccessibilityProcessIdentity, window: AXUIElement? = nil) {
        observedFocus = (process, element, window)
    }

    private func matchingObservedElement(in application: AXUIElement, process: AccessibilityProcessIdentity) -> AXUIElement? {
        guard let observedFocus,
              observedFocus.process == process,
              client.isFocused(observedFocus.element) else {
            return nil
        }
        if let window = observedFocus.window {
            guard let current = client.focusedWindow(in: application), CFEqual(window, current) else { return nil }
        }
        #if DEBUG && VOXKEY_LOCAL_DIAGNOSTICS && !VOXKEY_RELEASE
        logger.notice(
            "focus resolved route=observed_event pid=\(process.processIdentifier, privacy: .public)"
        )
        #endif
        return observedFocus.element
    }

    private func matchingFocusedElement(
        in application: AXUIElement,
        process: AccessibilityProcessIdentity
    ) -> AXUIElement? {
        // An application's own focused-element answer is authoritative. A web
        // renderer may own that AX element in a different process. The global
        // fallback has no such ownership relationship and remains PID-checked.
        if let focused = client.focusedElement(in: application) {
            return isFocusContainer(focused) ? nil : focused
        }
        guard let focused = client.systemWideFocusedElement(),
              client.processIdentifier(of: focused) == process.processIdentifier,
              !isFocusContainer(focused) else {
            return nil
        }
        #if DEBUG && VOXKEY_LOCAL_DIAGNOSTICS && !VOXKEY_RELEASE
        logger.notice(
            "focus resolved route=system_wide pid=\(process.processIdentifier, privacy: .public)"
        )
        #endif
        return focused
    }

    private func isFocusContainer(_ element: AXUIElement) -> Bool {
        // WebKit can report the page or its scroll view while a descendant
        // editor also owns focus. Continue resolution instead of caching the
        // container and preventing the bounded editor search. AXGroup remains
        // authoritative because some rich editors use that role themselves.
        switch client.role(of: element) {
        case "AXWebArea", "AXScrollArea": true
        default: false
        }
    }

    private func focusedEditorInWindow(of application: AXUIElement) -> (element: AXUIElement, window: AXUIElement)? {
        let started = ContinuousClock.now
        var visited: [AXUIElement] = []
        var candidates: [AXUIElement] = []
        func rejected(_ reason: String) -> (element: AXUIElement, window: AXUIElement)? {
            #if DEBUG && VOXKEY_LOCAL_DIAGNOSTICS && !VOXKEY_RELEASE
            let elapsed = started.duration(to: .now).components
            let milliseconds = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
            logger.notice("focus search rejected pid=\(self.client.processIdentifier(of: application) ?? 0, privacy: .public) reason=\(reason, privacy: .public) visited=\(visited.count, privacy: .public) candidates=\(candidates.count, privacy: .public) elapsed_ms=\(milliseconds, privacy: .public)")
            #endif
            return nil
        }
        guard let window = client.focusedWindow(in: application) else { return rejected("no_focused_window") }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(100))
        // Conversation history can place the composer beyond 128 AX nodes.
        // Keep the time/depth bounds and require the search to finish.
        let limit = 512
        let editorRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSecureTextField"]
        var pending: [(element: AXUIElement, depth: Int, editorAncestor: AXUIElement?)] = [(window, 0, nil)]

        while let node = pending.popLast() {
            guard visited.count < limit else { return rejected("node_limit") }
            guard ContinuousClock.now < deadline else { return rejected("time_limit") }
            if visited.contains(where: { CFEqual($0, node.element) }) { continue }
            visited.append(node.element)
            var editorAncestor = node.editorAncestor
            if client.isFocused(node.element), let role = client.role(of: node.element), editorRoles.contains(role) {
                // Prefer the text field inside a focused combo box, but refuse
                // unrelated editors that both claim focus.
                if let editorAncestor { candidates.removeAll { CFEqual($0, editorAncestor) } }
                candidates.append(node.element)
                guard candidates.count == 1 else { return rejected("ambiguous_editors") }
                editorAncestor = node.element
            }
            let remaining = limit - visited.count - pending.count
            guard let children = client.children(of: node.element, limit: remaining + 1) else {
                return rejected("children_unavailable")
            }
            guard children.count <= remaining else { return rejected("node_limit") }
            guard node.depth < 12 || children.isEmpty else { return rejected("depth_limit") }
            for child in children.reversed() {
                pending.append((child, node.depth + 1, editorAncestor))
            }
        }

        guard candidates.count == 1 else { return rejected("no_focused_editor") }
        guard ContinuousClock.now < deadline else { return rejected("time_limit") }
        guard let currentWindow = client.focusedWindow(in: application), CFEqual(window, currentWindow) else {
            return rejected("window_changed")
        }
        guard client.isFocused(candidates[0]) else { return rejected("editor_lost_focus") }
        return (candidates[0], window)
    }

    private func removeStaleLaunches(for process: AccessibilityProcessIdentity) {
        enablementByProcess = enablementByProcess.filter { identity, _ in
            identity.processIdentifier != process.processIdentifier || identity == process
        }
    }
}
