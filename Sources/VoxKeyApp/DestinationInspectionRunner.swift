#if DEBUG && VOXKEY_LOCAL_DIAGNOSTICS && !VOXKEY_RELEASE
import AppKit
import ApplicationServices

/// Read-only, content-free diagnosis through the same AX boundary as dictation.
/// Never activates an app, reads editor text, records audio, or writes editor content.
@MainActor
final class DestinationInspectionRunner: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.prohibited)
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--inspect-destination"),
              arguments.count > index + 2, let pid = Int32(arguments[index + 1]),
              let app = NSRunningApplication(processIdentifier: pid) else { exit(2) }
        let client = SystemDesktopAccessibilityClient()
        guard client.trusted else {
            print("Accessibility authorization unavailable for the inspection build.")
            exit(2)
        }
        let focusClient = SystemFocusedElementClient()
        let root = AXUIElementCreateApplication(pid)
        let identity = AccessibilityProcessIdentity(processIdentifier: pid, launchDate: app.launchDate)
        func describe(_ element: AXUIElement?) -> [String: Any] {
            guard let element else { return ["available": false] }
            var report: [String: Any] = [
                "available": true, "pid": focusClient.processIdentifier(of: element) ?? 0,
                "role": focusClient.role(of: element) ?? "unknown",
                "focused": focusClient.isFocused(element),
                "selectedTextSettable": client.isSettable(element, kAXSelectedTextAttribute),
                "valueSettable": client.isSettable(element, kAXValueAttribute),
                "attributes": client.attributeNames(element).sorted()
            ]
            for name in ["AXEditable", kAXEnabledAttribute, kAXSubroleAttribute] {
                if let value = client.attribute(element, name) as? NSNumber { report[name] = value }
                else if name == kAXSubroleAttribute, let value = client.attribute(element, name) as? String {
                    report[name] = value
                }
            }
            if let value = client.attribute(element, kAXSelectedTextRangeAttribute),
               CFGetTypeID(value) == AXValueGetTypeID() {
                let axValue = value as! AXValue
                var range = CFRange()
                if AXValueGetType(axValue) == .cfRange, AXValueGetValue(axValue, .cfRange, &range) {
                    report["selectionAvailable"] = range.location >= 0 && range.length >= 0
                }
            }
            return report
        }
        var report: [String: Any] = [
            "application": app.bundleIdentifier ?? "unknown", "pid": pid,
            "frontmost": NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
            "applicationFocus": describe(focusClient.focusedElement(in: root)),
            "systemFocus": describe(focusClient.systemWideFocusedElement())
        ]
        let resolver = FocusedElementResolver(client: focusClient)
        report["resolvedFocus"] = describe(resolver.resolve(in: root, process: identity))
        var pending: [(AXUIElement, Int)] = [(focusClient.focusedWindow(in: root) ?? root, 0)]
        var nodes: [[String: Any]] = []
        var truncated = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !pending.isEmpty, nodes.count < 512, ContinuousClock.now < deadline {
            let (element, depth) = pending.removeLast()
            var node = describe(element)
            node["depth"] = depth
            nodes.append(node)
            if let children = focusClient.children(of: element, limit: 129) {
                if children.count > 128 || (depth >= 16 && !children.isEmpty) { truncated = true }
                for child in (depth < 16 ? Array(children.prefix(128)) : []).reversed() {
                    pending.append((child, depth + 1))
                }
            } else { truncated = true }
        }
        report["windowNodes"] = nodes
        report["treeComplete"] = !truncated && pending.isEmpty
        do {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: arguments[index + 2]), options: .atomic)
            print("Content-free destination inspection written.")
            exit(0)
        } catch {
            print("Could not write inspection: \(error)")
            exit(2)
        }
    }
}
#endif
