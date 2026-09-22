import AppKit
import ApplicationServices
import Carbon.HIToolbox

struct DestinationApplication {
    let identity: AccessibilityProcessIdentity
    let name: String
}

/// The operating-system boundary. Tests substitute the OS, never delivery policy.
@MainActor
protocol DesktopAccessibilityClient: AnyObject {
    var trusted: Bool { get }
    var secureInputEnabled: Bool { get }
    var modifiersPressed: Bool { get }
    var frontmostApplication: DestinationApplication? { get }
    func application(processIdentifier: pid_t) -> DestinationApplication?
    func activate(processIdentifier: pid_t)
    func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef?
    func attributeNames(_ element: AXUIElement) -> Set<String>
    func isSettable(_ element: AXUIElement, _ name: String) -> Bool
    func setAttribute(_ element: AXUIElement, _ name: String, _ value: CFTypeRef) -> AXError
    func string(_ element: AXUIElement, range: CFRange) -> String?
    func postPaste(processIdentifier: pid_t) -> Bool
}

@MainActor
final class SystemDesktopAccessibilityClient: DesktopAccessibilityClient {
    init() {
        // Apple documents that a system-wide element sets this client's global
        // timeout. Setting it only on an application does not cover its children.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.1)
    }

    var trusted: Bool { AXIsProcessTrusted() }
    var secureInputEnabled: Bool { IsSecureEventInputEnabled() }
    var modifiersPressed: Bool {
        !CGEventSource.flagsState(.combinedSessionState)
            .intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl, .maskSecondaryFn]).isEmpty
    }
    var frontmostApplication: DestinationApplication? {
        NSWorkspace.shared.frontmostApplication.map(describe)
    }
    func application(processIdentifier: pid_t) -> DestinationApplication? {
        NSRunningApplication(processIdentifier: processIdentifier).map(describe)
    }
    func activate(processIdentifier: pid_t) {
        guard let destination = NSRunningApplication(processIdentifier: processIdentifier) else { return }
        NSApp.yieldActivation(to: destination)
        if !destination.activate(from: .current, options: []) { destination.activate() }
    }
    private func describe(_ application: NSRunningApplication) -> DestinationApplication {
        DestinationApplication(
            identity: AccessibilityProcessIdentity(
                processIdentifier: application.processIdentifier, launchDate: application.launchDate
            ),
            name: application.localizedName ?? "Unknown Application"
        )
    }
    func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        #if VOXKEY_PERFORMANCE && !VOXKEY_RELEASE
        DestinationDiagnostics.current?.axError(result.rawValue, operation: name)
        #endif
        guard result == .success else { return nil }
        return value
    }
    func attributeNames(_ element: AXUIElement) -> Set<String> {
        var names: CFArray?
        let result = AXUIElementCopyAttributeNames(element, &names)
        #if VOXKEY_PERFORMANCE && !VOXKEY_RELEASE
        DestinationDiagnostics.current?.axError(result.rawValue, operation: "AXAttributeNames")
        #endif
        guard result == .success,
              let strings = names as? [String] else { return [] }
        return Set(strings)
    }
    func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var settable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(element, name as CFString, &settable)
        #if VOXKEY_PERFORMANCE && !VOXKEY_RELEASE
        DestinationDiagnostics.current?.axError(result.rawValue, operation: "AXIsAttributeSettable")
        #endif
        return result == .success && settable.boolValue
    }
    func setAttribute(_ element: AXUIElement, _ name: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(element, name as CFString, value)
    }
    func string(_ element: AXUIElement, range: CFRange) -> String? {
        guard range.location >= 0, range.length >= 0 else { return nil }
        guard range.length > 0 else { return "" }
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        let plainResult = AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value
        )
        #if VOXKEY_PERFORMANCE && !VOXKEY_RELEASE
        DestinationDiagnostics.current?.axError(plainResult.rawValue, operation: "AXStringForRange")
        #endif
        if plainResult == .success, let string = value as? String { return string }
        // Some native editors expose only the attributed variant. Never read
        // AXValue as a fallback: that would fetch the entire document.
        let attributedResult = AXUIElementCopyParameterizedAttributeValue(
            element, kAXAttributedStringForRangeParameterizedAttribute as CFString, parameter, &value
        )
        #if VOXKEY_PERFORMANCE && !VOXKEY_RELEASE
        DestinationDiagnostics.current?.axError(attributedResult.rawValue, operation: "AXAttributedStringForRange")
        #endif
        if attributedResult == .success, let string = value as? NSAttributedString { return string.string }
        return nil
    }
    func postPaste(processIdentifier: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .privateState) else { return false }
        let steps: [(CGKeyCode, Bool, CGEventFlags)] = [
            (CGKeyCode(kVK_Command), true, .maskCommand),
            (CGKeyCode(kVK_ANSI_V), true, .maskCommand),
            (CGKeyCode(kVK_ANSI_V), false, .maskCommand),
            (CGKeyCode(kVK_Command), false, [])
        ]
        // Construct the entire chord before posting any part of it. Target the
        // validated process so switching applications cannot redirect the chord.
        var events: [CGEvent] = []
        for (key, down, flags) in steps {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return false }
            event.flags = flags
            events.append(event)
        }
        for event in events { event.postToPid(processIdentifier) }
        return true
    }
}
