import AppKit
import Testing
@testable import VoxKeyApp
import VoxKeyCore

@MainActor
@Test(arguments: [
    "Accessibility access is required — open Safety Net",
    "Destination changed — open Safety Net"
])
func statusOverlayPreservesTheFullRecoveryInstruction(_ message: String) throws {
    _ = NSApplication.shared
    let controller = StatusOverlayController()
    controller.update(SessionSnapshot(phase: .ready, lastResult: LastResult(text: "Private dictation"), message: message, attention: .deliveryBlocked(.destinationChanged)))
    defer { controller.window?.orderOut(nil) }
    let window = try #require(controller.window)
    let root = try #require(window.contentView)
    root.layoutSubtreeIfNeeded()
    let labels = root.overlayDescendants.compactMap { $0 as? NSTextField }
    let instruction = try #require(labels.first { $0.stringValue == message })
    let requiredHeight = try #require(instruction.cell?.cellSize(forBounds: NSRect(
        x: 0, y: 0, width: instruction.bounds.width, height: 1000
    )).height)
    #expect(instruction.bounds.height >= requiredHeight - 1)
    #expect(root.bounds.contains(root.convert(instruction.bounds, from: instruction)))
    #expect(instruction.lineBreakMode == .byWordWrapping)
    #expect(window.styleMask.contains(.nonactivatingPanel))
    #expect(window.ignoresMouseEvents)
    #expect(!labels.contains { $0.stringValue.contains("Private dictation") })
}

@MainActor
@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
func statusOverlayKeepsCaptureToOneCompactStatus(_ appearance: NSAppearance.Name) throws {
    _ = NSApplication.shared
    let controller = StatusOverlayController()
    controller.window?.appearance = NSAppearance(named: appearance)
    controller.update(SessionSnapshot(
        phase: .capturing(DictationSessionID()), lastResult: nil, elapsedSeconds: 75,
        message: "Listening", inputLevel: 0.8
    ))
    defer { controller.window?.orderOut(nil) }
    let window = try #require(controller.window)
    let root = try #require(window.contentView)
    root.layoutSubtreeIfNeeded()
    let labels = root.overlayDescendants.compactMap { $0 as? NSTextField }
    #expect(labels.map(\.stringValue) == ["Listening", "fn"])
    #expect(window.frame.width == 212)
    #expect(window.frame.height == 46)
    if let directory = ProcessInfo.processInfo.environment["VOXKEY_SETTINGS_PREVIEW_DIR"] {
        let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(
            to: URL(fileURLWithPath: directory).appendingPathComponent("listening-\(appearance.rawValue).png"))
    }
}

private extension NSView {
    var overlayDescendants: [NSView] { [self] + subviews.flatMap(\.overlayDescendants) }
}

@MainActor
@Test
func retainedTextAndStatusMessagesCannotCreateAFailureToast() {
    let controller = StatusOverlayController()
    defer { controller.window?.orderOut(nil) }
    controller.update(SessionSnapshot(
        phase: .ready, lastResult: LastResult(text: "Hello", deliveryUncertain: true),
        message: "Check the input before retrying"
    ))
    #expect(controller.window?.isVisible == false)
}

@MainActor @Test(arguments: [CaptureMode.hold, .toggle], DictationTrigger.allCases)
func capturingLevelStaysInsideTheCompactPillAndHidesAfterCapture(_ mode: CaptureMode, _ trigger: DictationTrigger) throws {
    _ = NSApplication.shared
    let overlay = StatusOverlayController()
    let id = DictationSessionID()
    overlay.update(SessionSnapshot(phase: .capturing(id), lastResult: nil, captureMode: mode,
                                   trigger: trigger, inputLevel: 0.65))
    let window = try #require(overlay.window)
    let root = try #require(window.contentView)
    root.layoutSubtreeIfNeeded()
    let meter = try #require(root.overlayDescendants.compactMap { $0 as? InputLevelBar }.first)
    #expect(!meter.isHidden)
    #expect(meter.level == 0.65)
    let keyLabel = try #require(root.overlayDescendants.compactMap { $0 as? NSTextField }.first {
        $0.accessibilityLabel() == trigger.displayName
    })
    #expect(!keyLabel.isHiddenOrHasHiddenAncestor)
    #expect(window.frame.width >= 164 && window.frame.width <= 360)
    for view in root.overlayDescendants where view is NSTextField || view === meter {
        #expect(root.bounds.insetBy(dx: -1, dy: -1).contains(root.convert(view.bounds, from: view)))
    }
    overlay.update(SessionSnapshot(phase: .finalizing(id), lastResult: nil))
    #expect(meter.isHidden)
    #expect(keyLabel.isHiddenOrHasHiddenAncestor)
    window.orderOut(nil)
}

@MainActor @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
func toggleWarningAndLevelRemainReadableInBothAppearances(_ appearance: NSAppearance.Name) throws {
    let controller = StatusOverlayController()
    controller.window?.appearance = NSAppearance(named: appearance)
    controller.update(.init(phase: .capturing(DictationSessionID()), lastResult: nil,
                            message: "Dictation ends automatically in 1:10", captureMode: .toggle,
                            trigger: .rightCommand, inputLevel: 0.7))
    defer { controller.window?.orderOut(nil) }
    let root = try #require(controller.window?.contentView)
    root.layoutSubtreeIfNeeded()
    let label = try #require(root.overlayDescendants.compactMap { $0 as? NSTextField }.first)
    #expect(label.stringValue.contains("press Right Command to finish"))
    let height = try #require(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.bounds.width, height: 1000)).height)
    #expect(label.bounds.height >= height - 1)
    if let directory = ProcessInfo.processInfo.environment["VOXKEY_SETTINGS_PREVIEW_DIR"] {
        let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(
            to: URL(fileURLWithPath: directory).appendingPathComponent("overlay-\(appearance.rawValue).png"))
    }
}

@MainActor @Test
func levelUpdatesPreserveOverlayPlacementButPresentationChangesRestoreIt() throws {
    _ = NSApplication.shared
    let overlay = StatusOverlayController()
    defer { overlay.window?.orderOut(nil) }
    let id = DictationSessionID()
    overlay.update(SessionSnapshot(phase: .capturing(id), lastResult: nil, inputLevel: 0.2))
    let window = try #require(overlay.window)
    let moved = NSPoint(x: window.frame.minX - 30, y: window.frame.minY - 30)
    window.setFrameOrigin(moved)
    overlay.update(SessionSnapshot(phase: .capturing(id), lastResult: nil, inputLevel: 0.8))
    #expect(window.frame.origin == moved)
    let meter = try #require(window.contentView?.overlayDescendants.compactMap { $0 as? InputLevelBar }.first)
    #expect(meter.level == 0.8)
    overlay.update(SessionSnapshot(phase: .capturing(id), lastResult: nil, message: "Capture limit approaching", inputLevel: 0.8))
    #expect(window.frame.origin != moved)
    window.orderOut(nil)
    overlay.update(SessionSnapshot(phase: .capturing(id), lastResult: nil, message: "Capture limit approaching", inputLevel: 0.8))
    #expect(window.isVisible)
}

@MainActor @Test
func screenConfigurationChangesRepositionAVisibleOverlay() throws {
    _ = NSApplication.shared
    let overlay = StatusOverlayController()
    defer { overlay.window?.orderOut(nil) }
    overlay.update(SessionSnapshot(phase: .capturing(DictationSessionID()), lastResult: nil))
    let window = try #require(overlay.window)
    let original = window.frame.origin
    window.setFrameOrigin(NSPoint(x: original.x - 30, y: original.y - 30))
    NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
    #expect(window.frame.origin == original)
    window.orderOut(nil)
    NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
    #expect(!window.isVisible)
}
