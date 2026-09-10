import AppKit
import Testing
@testable import VoxKeyApp
import VoxKeyCore

@MainActor
@Test
func grantedPermissionRowsKeepTheirIntrinsicSpacing() throws {
    _ = NSApplication.shared
    let controller = OnboardingWindowController()
    controller.update(
        microphone: true,
        accessibility: true,
        modelPhase: .required,
        message: "Prepare the English transcription model."
    )

    let root = try #require(controller.window?.contentView)
    root.layoutSubtreeIfNeeded()

    let subtitle = try #require(root.textField(containing: "VoxKey transcribes entirely"))
    let microphone = try #require(root.textField(containing: "Microphone"))
    let accessibility = try #require(root.textField(containing: "Accessibility"))
    let model = try #require(root.textField(containing: "English model"))

    let subtitleFrame = root.convert(subtitle.bounds, from: subtitle)
    let microphoneFrame = root.convert(microphone.bounds, from: microphone)
    let accessibilityFrame = root.convert(accessibility.bounds, from: accessibility)
    let modelFrame = root.convert(model.bounds, from: model)

    #expect(!subtitleFrame.intersects(microphoneFrame))
    #expect(abs(microphoneFrame.midY - accessibilityFrame.midY) < 50)
    #expect(abs(accessibilityFrame.midY - modelFrame.midY) < 50)
}

@MainActor
@Test
func onboardingOffersOnePrerequisiteActionAtATime() throws {
    _ = NSApplication.shared
    let controller = OnboardingWindowController()
    let root = try #require(controller.window?.contentView)

    controller.update(
        microphone: false,
        accessibility: false,
        modelPhase: .required,
        message: nil
    )
    #expect(root.visibleButtonTitles == ["Continue"])

    controller.update(
        microphone: true,
        accessibility: false,
        modelPhase: .required,
        message: nil
    )
    #expect(root.visibleButtonTitles == ["Open System Settings"])

    controller.update(
        microphone: true,
        accessibility: true,
        modelPhase: .required,
        message: nil
    )
    #expect(root.visibleButtonTitles == ["Prepare English Model"])
}

@MainActor
@Test
func successfulReadinessCheckOffersAnExplicitFinishAction() throws {
    _ = NSApplication.shared
    let controller = OnboardingWindowController()
    let root = try #require(controller.window?.contentView)
    var finishRequested = false
    controller.onFinish = { finishRequested = true }

    controller.update(
        microphone: true,
        accessibility: true,
        modelPhase: .ready,
        message: "Delivered"
    )
    controller.markComplete()

    #expect(root.visibleButtonTitles == ["Finish Setup"])
    #expect(controller.testTextView.isEditable == false)

    let finishButton = try #require(root.descendants.compactMap { $0 as? NSButton }.first { $0.title == "Finish Setup" })
    finishButton.performClick(nil)
    #expect(finishRequested)
}

@MainActor
@Test(arguments: [
    (false, false, ModelPreparationPhase.required),
    (true, false, .required),
    (true, true, .required),
    (true, true, .downloading(0.42)),
    (true, true, .prewarming),
    (true, true, .failed),
    (true, true, .ready)
])
func onboardingKeepsEverySetupStateInsideTheWindow(_ microphone: Bool, _ accessibility: Bool, _ phase: ModelPreparationPhase) throws {
    _ = NSApplication.shared
    let controller = OnboardingWindowController()
    controller.update(
        microphone: microphone,
        accessibility: accessibility,
        modelPhase: phase,
        message: "Prepare the English transcription model. Your audio and words stay on this Mac."
    )
    let root = try #require(controller.window?.contentView)
    root.layoutSubtreeIfNeeded()
    for view in root.descendants where (view is NSControl || view === controller.testTextView) && !view.isHiddenOrHasHiddenAncestor {
        let frame = root.convert(view.bounds, from: view)
        #expect(root.bounds.insetBy(dx: -1, dy: -1).contains(frame))
    }
    #expect(controller.testTextView.bounds.width > 300)
    #expect(controller.testTextView.bounds.height >= 80)
}

@MainActor
@Test
func resettingOnboardingRestoresTheEditableReadinessCheck() throws {
    _ = NSApplication.shared
    let controller = OnboardingWindowController()
    controller.update(microphone: true, accessibility: true, modelPhase: .ready, message: nil)
    controller.markComplete()
    controller.resetCompletionState()
    let root = try #require(controller.window?.contentView)
    #expect(controller.testTextView.isEditable)
    #expect(root.visibleButtonTitles.isEmpty)
    #expect(root.textField(containing: "READINESS CHECK") != nil)
}

private extension NSView {
    var visibleButtonTitles: [String] {
        descendants
            .compactMap { $0 as? NSButton }
            .filter { !$0.isHiddenOrHasHiddenAncestor }
            .map(\.title)
    }

    var descendants: [NSView] {
        [self] + subviews.flatMap(\.descendants)
    }

    func textField(containing text: String) -> NSTextField? {
        if let field = self as? NSTextField, field.stringValue.contains(text) {
            return field
        }
        return subviews.lazy.compactMap { $0.textField(containing: text) }.first
    }
}

@MainActor @Test(arguments: [NSAppearance.Name.aqua, .darkAqua], [false, true])
func dictationSettingsFitInBothAppearances(_ appearance: NSAppearance.Name, _ grammarAvailable: Bool) throws {
    _ = NSApplication.shared
    let controller = OnboardingWindowController(grammarAvailable: grammarAvailable)
    controller.window?.appearance = NSAppearance(named: appearance)
    controller.updateTrigger(.rightCommand)
    controller.updateCaptureMode(.toggle)
    controller.updateLaunchAtLogin(enabled: true)
    controller.updateMicrophones(.init(devices: [
        .init(id: 1, uid: "synthetic", name: "Synthetic microphone with a very long descriptive name for layout validation")
    ], defaultID: 1), pinnedUID: "synthetic")
    controller.showSettings()
    let root = try #require(controller.window?.contentView)
    root.layoutSubtreeIfNeeded()
    for view in root.descendants where view is NSControl && !view.isHiddenOrHasHiddenAncestor {
        #expect(root.bounds.insetBy(dx: -1, dy: -1).contains(root.convert(view.bounds, from: view)))
    }
    if let directory = ProcessInfo.processInfo.environment["VOXKEY_SETTINGS_PREVIEW_DIR"] {
        let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("settings-\(appearance.rawValue)-grammar-\(grammarAvailable).png"))
    }
}
