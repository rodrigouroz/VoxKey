import AppKit
import Testing
import VoxKeyCore
@testable import VoxKeyApp

@MainActor @Test
func firstModelActivationUsesTheLanguageChosenBeforeDownloadFinishes() throws {
    _ = NSApplication.shared
    let controller = ModelSettingsWindowController()
    let configuration = TranscriptionConfiguration()
    controller.update(active: configuration, ready: false, installed: [], busy: false)
    #expect(!controller.languagePopup.isHiddenOrHasHiddenAncestor)
    #expect(controller.languagePopup.isEnabled)
    controller.languagePopup.selectItem(withTitle: TranscriptionModel.languageName("es"))
    _ = controller.languagePopup.sendAction(controller.languagePopup.action, to: controller.languagePopup.target)
    controller.update(active: configuration, ready: false, installed: [.turboCompressed, .distilCompressed], busy: false)
    var selected: TranscriptionConfiguration?
    controller.onActivate = { selected = $0 }
    let english = try #require(controller.cards.first { $0.model == .distilCompressed })
    #expect(!english.actionButton.isEnabled)
    let turbo = try #require(controller.cards.first { $0.model == .turboCompressed })
    turbo.actionButton.performClick(nil)
    #expect(selected == TranscriptionConfiguration(model: .turboCompressed, language: "es"))
}

@MainActor @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
func onboardingExposesLanguageAndShortcutBeforeTheFirstDictation(_ appearance: NSAppearance.Name) throws {
    _ = NSApplication.shared
    let controller = OnboardingWindowController()
    controller.window?.appearance = NSAppearance(named: appearance)
    controller.update(microphone: true, accessibility: true, modelPhase: .ready, message: nil)
    controller.updateDictationChoices(configuration: .init(model: .turboCompressed), ready: true, busy: false)
    #expect(!controller.languagePopup.isHiddenOrHasHiddenAncestor)
    #expect(!controller.triggerPopup.isHiddenOrHasHiddenAncestor)
    var language: String?
    var trigger: DictationTrigger?
    controller.onLanguageChanged = { language = $0 }
    controller.onTriggerChanged = { trigger = $0 }
    controller.languagePopup.selectItem(withTitle: TranscriptionModel.languageName("es"))
    _ = controller.languagePopup.sendAction(controller.languagePopup.action, to: controller.languagePopup.target)
    controller.triggerPopup.selectItem(withTitle: DictationTrigger.rightCommand.displayName)
    _ = controller.triggerPopup.sendAction(controller.triggerPopup.action, to: controller.triggerPopup.target)
    #expect(language == "es")
    #expect(trigger == .rightCommand)
    #expect(controller.dictationTrigger == .rightCommand)
    let root = try #require(controller.window?.contentView)
    root.layoutSubtreeIfNeeded()
    if let directory = ProcessInfo.processInfo.environment["VOXKEY_SETTINGS_PREVIEW_DIR"] {
        let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("onboarding-choices-\(appearance.rawValue).png"))
    }
    controller.updateDictationChoices(configuration: .init(model: .turboCompressed, language: "es"), ready: true, busy: true)
    #expect(!controller.languagePopup.isEnabled)
    #expect(!controller.triggerPopup.isEnabled)
    controller.updateDictationChoices(configuration: .init(), ready: true, busy: false)
    #expect(!controller.languagePopup.isEnabled)
    #expect(controller.languageHint.stringValue.contains("English only"))
}

@MainActor @Test
func modelDownloadFeedbackCoversStartupTransferFinalizationAndRetry() throws {
    _ = NSApplication.shared
    let setup = OnboardingWindowController()
    let models = ModelSettingsWindowController()
    let card = try #require(models.cards.first { $0.model == .turboCompressed })
    for fraction in [0.0, 0.42, 1.0, 0.0] {
        let status = ModelDownloadStatus(fraction: fraction, elapsed: 75)
        setup.update(microphone: true, accessibility: true, modelPhase: .downloading(fraction),
                     message: nil, downloadStatus: status)
        models.update(active: .init(), ready: false, installed: [], busy: false,
                      downloading: .turboCompressed, downloadProgress: fraction, downloadElapsed: 75)
        #expect(!setup.modelProgress.isHidden)
        #expect(!card.progress.isHidden)
        #expect(setup.modelProgress.isIndeterminate == (fraction != 0.42))
        #expect(card.progress.isIndeterminate == (fraction != 0.42))
        #expect(card.stateLabel.stringValue == status.title)
        #expect(models.statusLabel.stringValue.contains("1m 15s elapsed"))
        #expect(models.statusLabel.stringValue.contains("Time remaining unavailable"))
        if let directory = ProcessInfo.processInfo.environment["VOXKEY_SETTINGS_PREVIEW_DIR"], fraction < 1 {
            for (name, window) in [("setup", setup.window), ("models", models.window)] {
                let root = try #require(window?.contentView)
                root.layoutSubtreeIfNeeded()
                let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
                root.cacheDisplay(in: root.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)-download-\(fraction).png"))
            }
        }
    }
    setup.update(microphone: true, accessibility: true, modelPhase: .failed, message: "Try again")
    models.update(active: .init(), ready: false, installed: [], busy: false, message: "Try again")
    #expect(setup.modelProgress.isHidden)
    #expect(card.progress.isHidden)
    #expect(card.actionButton.isEnabled)
    #expect(models.statusLabel.stringValue == "Try again")
}
