#if DEBUG
import AppKit
import ApplicationServices
import Foundation
import VoxKeyCore

/// Development-only, synthetic validation against the non-shipping test host.
/// This never creates AppController, opens a microphone, or loads a model.
@MainActor
final class DeliveryValidationRunner: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.prohibited)
        Task { await run() }
    }

    private func run() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--verify-delivery"), arguments.count > index + 4,
              let count = Int(arguments[index + 1]), (1...50).contains(count) else {
            print("Usage: VoxKey --verify-delivery <1...50> <report.json> <oracle.json> <nativeField|nativeText|web>")
            exit(2)
        }
        let client = SystemDesktopAccessibilityClient()
        guard client.trusted else {
            print("The validation app does not have Accessibility authorization. Launch the signed bundle through Launch Services.")
            exit(2)
        }
        let fixtureBundle = "com.rodrigouroz.VoxKey.TestHost"
        guard let host = NSRunningApplication.runningApplications(withBundleIdentifier: fixtureBundle).first else {
            print("Open the fixture application and focus an empty editor first.")
            exit(2)
        }
        NSApp.yieldActivation(to: host)
        _ = host.activate(from: .current, options: [])
        let activationDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != host.processIdentifier,
              ContinuousClock.now < activationDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let resolver = FocusedElementResolver()
        let service = AccessibilityService(client: client, focusedElementResolver: resolver)
        var records: [[String: Any]] = []
        var failure: String?
        let oracleURL = URL(fileURLWithPath: arguments[index + 3])
        let fixture = arguments[index + 4]
        func oracle() -> [String: String]? {
            guard let data = try? Data(contentsOf: oracleURL) else { return nil }
            return try? JSONDecoder().decode([String: String].self, from: data)
        }
        guard let originalEditors = oracle(), originalEditors[fixture] == "" else {
            print("Reset the selected fixture to empty and supply its independent oracle report.")
            exit(2)
        }
        let phrase = "Hello from VoxKey."
        let savedClipboard = PasteboardSnapshot.capture(.general)

        for iteration in 1...count {
            guard let app = NSWorkspace.shared.frontmostApplication,
                  app.bundleIdentifier == fixtureBundle else {
                failure = "Focus an empty editor in VoxKey Test Host before running the probe."
                break
            }
            let identity = AccessibilityProcessIdentity(processIdentifier: app.processIdentifier, launchDate: app.launchDate)
            let focusDeadline = ContinuousClock.now.advanced(by: arguments.contains("--wait-for-focus") ? .seconds(30) : .seconds(1))
            var focusedElement = resolver.resolve(in: AXUIElementCreateApplication(app.processIdentifier), process: identity)
            while focusedElement == nil, ContinuousClock.now < focusDeadline {
                try? await Task.sleep(for: .milliseconds(20))
                focusedElement = resolver.resolve(in: AXUIElementCreateApplication(app.processIdentifier), process: identity)
            }
            guard let element = focusedElement else {
                let focusClient = SystemFocusedElementClient()
                for (source, root) in [("application", AXUIElementCreateApplication(app.processIdentifier)), ("system", AXUIElementCreateSystemWide())] {
                    var value: CFTypeRef?
                    let error = AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &value)
                    print("Focus read source=\(source) ax_error=\(error.rawValue)")
                }
                for (source, focused) in [
                    ("application", focusClient.focusedElement(in: AXUIElementCreateApplication(app.processIdentifier))),
                    ("system", focusClient.systemWideFocusedElement())
                ] {
                    if let focused {
                        print("Unresolved focus source=\(source) app_pid=\(app.processIdentifier) element_pid=\(focusClient.processIdentifier(of: focused) ?? 0) role=\(client.attribute(focused, kAXRoleAttribute) as? String ?? "unknown")")
                    }
                }
                logSyntheticFocusTree(AXUIElementCreateApplication(app.processIdentifier), client: client)
                failure = "The test-host focused editor could not be resolved."
                break
            }
            let captureStart = ContinuousClock.now
            let destination = await service.captureCurrentDestination()
            let captureMilliseconds = milliseconds(since: captureStart)
            guard let token = destination.token else {
                failure = "Capture failed: \(String(describing: destination.failure))"
                break
            }
            let directAXWritable = client.isSettable(element, kAXSelectedTextAttribute)
            let start = ContinuousClock.now
            let outcome = await service.deliver(phrase, to: token)
            let elapsed = milliseconds(since: start)
            let expected = Array(repeating: phrase, count: iteration).joined(separator: " ")
            let oracleDeadline = ContinuousClock.now.advanced(by: .seconds(3))
            while oracle()?[fixture] != expected, ContinuousClock.now < oracleDeadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            let observed = oracle()
            let matches = observed?[fixture] == expected
                && originalEditors.allSatisfy { key, value in key == fixture || observed?[key] == value }
            records.append([
                "iteration": iteration, "captureMilliseconds": captureMilliseconds,
                "deliveryMilliseconds": elapsed, "outcome": String(describing: outcome),
                "exactTextMatches": matches, "directAXWritable": directAXWritable
            ])
            guard (outcome == .delivered || outcome == .unconfirmed), matches else {
                failure = "Delivery or independent exact-text verification failed."
                break
            }
        }
        await service.waitForPendingPaste()
        let clipboardPreserved = savedClipboard.map { original in
            guard let current = PasteboardSnapshot.capture(.general), original.items.count == current.items.count else { return false }
            return zip(original.items, current.items).allSatisfy { before, after in
                before.representations.count == after.representations.count
                    && zip(before.representations, after.representations).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
            }
        } ?? false
        let success = failure == nil && records.count == count && clipboardPreserved
        let report: [String: Any] = [
            "success": success, "failure": failure ?? "", "clipboardPreserved": clipboardPreserved,
            "oracle": "test-host editor storage and DOM", "fixture": fixture,
            "iterations": records, "date": ISO8601DateFormatter().string(from: Date())
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: arguments[index + 2]), options: .atomic)
        } catch {
            print("Could not write the synthetic delivery report: \(error)")
            exit(2)
        }
        print("Synthetic delivery validation: \(success ? "passed" : "failed"), \(records.count) iterations")
        exit(success ? 0 : 1)
    }

    private func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
    }

    private func logSyntheticFocusTree(_ root: AXUIElement, client: SystemDesktopAccessibilityClient) {
        let focusedWindow = client.attribute(root, kAXFocusedWindowAttribute) as! AXUIElement?
        print("Synthetic focused window available=\(focusedWindow != nil)")
        var queue: [(AXUIElement, Int)] = [(focusedWindow ?? root, 0)]
        var count = 0
        while !queue.isEmpty, count < 64 {
            let (element, depth) = queue.removeLast()
            count += 1
            var pid = pid_t()
            _ = AXUIElementGetPid(element, &pid)
            let role = client.attribute(element, kAXRoleAttribute) as? String ?? "unknown"
            let focused = (client.attribute(element, kAXFocusedAttribute) as? NSNumber)?.boolValue ?? false
            print("Synthetic focus node depth=\(depth) pid=\(pid) role=\(role) focused=\(focused)")
            if depth < 8 {
                for child in (client.attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(32).reversed() {
                    queue.append((child, depth + 1))
                }
            }
        }
    }
}
#endif
