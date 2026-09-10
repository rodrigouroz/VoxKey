import AppKit
import Foundation
import Testing
import VoxKeyCore
@preconcurrency import WhisperKit
@testable import VoxKeyApp

@Test func savedModelAndLanguageRoundTripAndOldPreferencesRemainEnglish() throws {
    let suite = "VoxKey.ModelSettingsTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(TranscriptionConfiguration(defaults: defaults) == TranscriptionConfiguration())
    let spanish = TranscriptionConfiguration(model: .turboCompressed, language: "es")
    spanish.save(to: defaults)
    #expect(TranscriptionConfiguration(defaults: defaults) == spanish)
    defaults.set("missing-model", forKey: TranscriptionModel.preferenceKey)
    #expect(TranscriptionConfiguration(defaults: defaults) == TranscriptionConfiguration())
}

@Test func unsupportedLanguagesCannotEnterAnEnglishOnlyModel() {
    for model in [TranscriptionModel.distilCompressed, .distilFull] {
        for language in ["es", "auto", "unknown"] {
            let configuration = TranscriptionConfiguration(model: model, language: language)
            #expect(configuration.decodingLanguage == "en")
        }
    }
    for model in [TranscriptionModel.turboCompressed, .turboFull] {
        #expect(TranscriptionConfiguration(model: model, language: "es").decodingLanguage == "es")
        #expect(TranscriptionConfiguration(model: model, language: "auto").decodingLanguage == nil)
        #expect(model.languages.contains("fr"))
    }
}

@Test func grammarCorrectionIsRestrictedToExplicitEnglishSessions() {
    for language in ["auto", "es", "fr", "de"] {
        #expect(!TranscriptionConfiguration(model: .turboFull, language: language).supportsGrammarCorrection)
    }
    #expect(TranscriptionConfiguration(model: .turboFull, language: "en").supportsGrammarCorrection)
}

@MainActor @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
func modelCardsKeepDownloadsSeparateFromActivation(_ appearance: NSAppearance.Name) throws {
    _ = NSApplication.shared
    let controller = ModelSettingsWindowController()
    controller.window?.appearance = NSAppearance(named: appearance)
    let current = TranscriptionConfiguration()
    let turbo = try #require(controller.cards.first { $0.model == .turboCompressed })
    let baseline = try #require(controller.cards.first { $0.model == .distilCompressed })
    var activated: TranscriptionConfiguration?
    var downloaded: TranscriptionModel?
    controller.onActivate = { activated = $0 }
    controller.onDownload = { downloaded = $0 }
    controller.update(active: current, ready: true, installed: [.distilCompressed], busy: false)
    #expect(controller.cards.count == 4)
    #expect(baseline.stateLabel.stringValue == "Active ✓")
    #expect(baseline.actionButton.isHidden)
    #expect(turbo.languageLabel.stringValue.contains("Spanish"))
    turbo.actionButton.performClick(nil)
    #expect(downloaded == .turboCompressed)
    #expect(activated == nil)
    controller.update(active: current, ready: true, installed: [.distilCompressed, .turboCompressed], busy: false)
    #expect(turbo.stateLabel.stringValue == "Downloaded")
    #expect(controller.activeLabel.stringValue.contains(current.model.name))
    turbo.actionButton.performClick(nil)
    #expect(activated == TranscriptionConfiguration(model: .turboCompressed))
    // Pending activation leaves the old model marked active until the app reports success.
    #expect(baseline.stateLabel.stringValue == "Active ✓")
    let spanish = TranscriptionConfiguration(model: .turboCompressed, language: "es")
    controller.update(active: spanish, ready: true, installed: Set(TranscriptionModel.allCases), busy: false)
    #expect(controller.grammarNote.stringValue.contains("paused"))
    controller.languagePopup.selectItem(at: 0)
    _ = controller.languagePopup.sendAction(controller.languagePopup.action, to: controller.languagePopup.target)
    #expect(activated == TranscriptionConfiguration(model: .turboCompressed, language: "auto"))
    controller.update(active: spanish, ready: true, installed: [.distilCompressed, .turboCompressed], busy: true,
                      downloading: .distilFull, downloadProgress: 0.4)
    #expect(!baseline.actionButton.isEnabled)
    #expect(!controller.languagePopup.isEnabled)
    #expect(turbo.stateLabel.stringValue == "Active ✓")
    let root = try #require(controller.window?.contentView)
    root.layoutSubtreeIfNeeded()
    #expect(abs(controller.cards[0].bounds.width - controller.cards[2].bounds.width) < 1)
    #expect(controller.cards[0].bounds.width > 360)
    for card in controller.cards {
        #expect(root.bounds.contains(root.convert(card.bounds, from: card)))
        for text in [card.languageLabel, card.stateLabel] {
            #expect(card.bounds.contains(card.convert(text.bounds, from: text)))
        }
    }
    if let directory = ProcessInfo.processInfo.environment["VOXKEY_SETTINGS_PREVIEW_DIR"] {
        for ready in [false, true] {
            controller.update(active: spanish, ready: ready, installed: ready ? [.distilCompressed, .turboCompressed] : [], busy: false)
            root.layoutSubtreeIfNeeded()
            let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("models-\(appearance.rawValue)-ready-\(ready).png"))
        }
    }
}

@Test func modelLibraryDiscoversMultipleDownloadsAndRejectsPartialFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = TranscriptionModelFiles(root: root)
    for model in [TranscriptionModel.distilCompressed, .turboFull] {
        for component in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            let file = try files.folder(for: model.rawValue).appendingPathComponent("\(component).mlmodelc/weights/weight.bin")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: file)
        }
    }
    #expect(files.installedModels() == [.distilCompressed, .turboFull])
    let truncated = try files.folder(for: TranscriptionModel.turboFull.rawValue).appendingPathComponent("TextDecoder.mlmodelc/weights/weight.bin")
    try Data().write(to: truncated)
    #expect(files.installedModels() == [.distilCompressed])
}

@MainActor @Test func modelLibraryIsReachableFromSetupAndSettings() throws {
    _ = NSApplication.shared
    let onboarding = OnboardingWindowController()
    let settings = SettingsWindowController()
    var setupOpened = false
    var settingsOpened = false
    onboarding.onChooseModel = { setupOpened = true }
    settings.onChooseModel = { settingsOpened = true }
    onboarding.update(microphone: true, accessibility: true, modelPhase: .required, message: nil)
    func findButton(_ view: NSView, title: String) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        return view.subviews.lazy.compactMap { findButton($0, title: title) }.first
    }
    let setupRoot = try #require(onboarding.window?.contentView)
    let settingsRoot = try #require(settings.window?.contentView)
    let setupButton = try #require(findButton(setupRoot, title: "Choose Model…"))
    #expect(!setupButton.isHiddenOrHasHiddenAncestor)
    setupButton.performClick(nil)
    try #require(findButton(settingsRoot, title: "Manage Models…")).performClick(nil)
    #expect(setupOpened && settingsOpened)
    for card in [onboarding.grammar, settings.grammar] {
        card.update(enabled: true, state: .ready)
        card.updateLanguage(supported: false)
        #expect(!card.checkbox.isEnabled)
        card.updateLanguage(supported: true)
        #expect(card.checkbox.isEnabled)
        #expect(card.checkbox.state == .on)
    }
}

@MainActor @Test func preparingAModelDuringDictationRejectsWithoutChangingConfiguration() async throws {
    var machine = SessionStateMachine()
    try machine.becomeReady()
    _ = try machine.beginSession()
    let coordinator = SessionCoordinator(initialState: machine)
    await #expect(throws: TranscriptionError.inferenceBusy) {
        try await coordinator.prepareModel(TranscriptionConfiguration(model: .turboFull, language: "es"), download: false)
    }
    #expect(await coordinator.transcriptionConfiguration == TranscriptionConfiguration())
}

@Test func spanishPunctuationAndAccentsSurviveTextDeliveryMechanics() {
    #expect(DictationMechanics.prepare(transcript: "cómo estás?", precedingText: "¿", followingText: "", replacesSelection: false) == "cómo estás?")
    #expect(DictationMechanics.prepare(transcript: "mañana", precedingText: "¡", followingText: "!", replacesSelection: false) == "mañana")
    #expect(DictationMechanics.prepare(transcript: "¿Podés revisarlo?", precedingText: "", followingText: "", replacesSelection: false) == "¿Podés revisarlo?")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VOXKEY_MULTILINGUAL_TEST_ROOT"] != nil))
func installedTurboTranscribesSpanishInBothPathsAndPreservesItsModelAfterFailedSwitch() async throws {
    let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["VOXKEY_MULTILINGUAL_TEST_ROOT"]))
    let transcriber = WhisperTranscriber(localModelRoot: root.appendingPathComponent("models"))
    let model = TranscriptionModel.turboCompressed.rawValue
    try await transcriber.prepare(model: model, download: false)
    let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: root.appendingPathComponent("audio/es-Paulina-short.aiff").path)
    for language: String? in ["es", nil] {
        let batch = try await transcriber.transcribe(.init(samples: samples, sampleRate: 16000, overflowed: false), language: language)
        let input = SyntheticAudioInput(sampleRate: 16000)
        let capture = AudioCaptureService(makeInput: { _ in input })
        try await capture.start()
        let worker = Task { try await transcriber.transcribeStream(from: capture, language: language) }
        input.emit(samples)
        try await capture.finish()
        let streamed = try await worker.value
        for outcome in [batch, streamed] {
            guard case let .final(text) = outcome else { Issue.record("Spanish speech must produce text"); continue }
            #expect(text.lowercased().contains("notas"))
            #expect(text.lowercased().contains("reunión"))
            #expect(!text.lowercased().contains("meeting"))
        }
    }
    await #expect(throws: TranscriptionError.modelNotInstalled) {
        try await transcriber.prepare(model: "missing-test-model-\(UUID().uuidString)", download: false)
    }
    #expect(await transcriber.selectedModel == model)
    guard case let .final(text) = try await transcriber.transcribe(.init(samples: samples, sampleRate: 16000, overflowed: false), language: "es") else {
        Issue.record("Previous model must remain usable after failed replacement")
        return
    }
    #expect(text.lowercased().contains("reunión"))
}
