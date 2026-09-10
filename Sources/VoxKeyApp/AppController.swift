import AppKit
import OSLog
import ServiceManagement
import VoxKeyCore

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private lazy var coordinator = SessionCoordinator(cuePlayer: cuePlayer)
    private let cuePlayer = CaptureCuePlayer()
    private let inputDeviceObserver = AudioInputDeviceObserver()
    private var inputCatalog = AudioInputCatalog()
    private let microphoneUIDKey = "VoxKeyMicrophoneUID"
    private let triggerMonitor = GlobalTriggerMonitor()
    private let updates = UpdateController()
    private let overlay = StatusOverlayController()
    let onboarding = OnboardingWindowController()
    private var modelSettings: ModelSettingsWindowController?
    private var activeModelReady = false
    private let modelLibrary = TranscriptionModelLibrary()
    private var installedModels: Set<TranscriptionModel> = []
    private var downloadingModel: TranscriptionModel?
    private var modelDownloadProgress = 0.0
    private var preparingModel: TranscriptionModel?
    private var modelSelectionMessage: String?
    private var transcriptionConfiguration: TranscriptionConfiguration { TranscriptionConfiguration(defaults: defaults) }
    let settings = SettingsWindowController()
    private lazy var vocabularyStore = Result { try VocabularyStore() }
    private var vocabularyWindow: VocabularyWindowController?

    private(set) var safetyNet: SafetyNetWindowController?
    private var statusItem: NSStatusItem?
    private var statusTimer: Timer?
    private var observationTask: Task<Void, Never>?
    private var modelObservationTask: Task<Void, Never>?
    private var grammarObservationTask: Task<Void, Never>?
    private var grammarPreferenceTask: Task<Void, Never>?
    private var focusObservationTask: Task<Void, Never>?
    private var triggerPreparationTask: Task<DictationSessionID?, Never>?
    private var focusSignalGeneration: UInt64 = 0
    private var latestSnapshot = SessionSnapshot(phase: .notReady(.onboarding), lastResult: nil)
    private var modelPhase: ModelPreparationPhase = .required
    private var modelPreparationTaskActive = false
    private var triggerStarted = false
    private var readinessCheckInFlight = false
    private var hasPresentedOnboarding = false
    private var runtimeMessage: String?
    private var launchAtLoginError: String?
    private struct OnboardingStatus: Equatable {
        let microphone: Bool
        let accessibility: Bool
        let modelPhase: ModelPreparationPhase
        let message: String?
    }
    private var renderedOnboardingStatus: OnboardingStatus?

    private let defaults: UserDefaults
    private let modelInstalledKey = "VoxKeyDefaultModelInstalled"
    private let onboardingCompleteKey = "VoxKeyOnboardingComplete"
    private var captureMode: CaptureMode { defaults.bool(forKey: "VoxKeyToggleDictation") ? .toggle : .hold }
    private let triggerKey = "VoxKeyDictationTrigger"
    private let cuesEnabledKey = "VoxKeyCaptureCuesEnabled"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        triggerMonitor.trigger = DictationTrigger(rawValue: defaults.string(forKey: triggerKey) ?? "") ?? .globe
        onboarding.onClose = { [weak self] in
            self?.finishOnboardingPresentation()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let buildID = Bundle.main.object(forInfoDictionaryKey: "VoxKeyBuildID") as? String ?? "development"
        Logger(subsystem: "com.rodrigouroz.VoxKey", category: "Lifecycle").notice("started build=\(buildID, privacy: .public)")
        NSApp.setActivationPolicy(.accessory)
        configureApplicationMenu()
        configureStatusItem()
        configureWindows()
        observeCoordinator()
        observeModelPreparation()
        updates.start()

        cuePlayer.enabled = defaults.object(forKey: cuesEnabledKey) as? Bool ?? true
        presentLaunchOnboardingIfNeeded(
            microphoneAuthorized: AudioCaptureService.microphoneAuthorized(),
            accessibilityTrusted: AccessibilityService.isTrusted
        )

        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshRuntimeState() }
        }

        Task { @MainActor in
            installedModels = await modelLibrary.installedModels()
            updateModelSettings()
            if defaults.bool(forKey: modelInstalledKey) {
                await prepareModel(download: false)
            } else {
                await coordinator.refreshReadiness()
            }
            await refreshRuntimeState()
            // A cached model may be missing or unreadable despite its saved installed flag.
            presentLaunchOnboardingIfNeeded(
                microphoneAuthorized: AudioCaptureService.microphoneAuthorized(),
                accessibilityTrusted: AccessibilityService.isTrusted
            )
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        triggerMonitor.stop()
        Task {
            await coordinator.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if needsSetup {
            presentOnboarding()
        } else if flag {
            // A model or Settings window may already be frontmost.
            NSApp.activate()
        } else {
            openSettings()
        }
        return false
    }

    /// Setup stays reachable until the first dictation is delivered and every check passes.
    private var needsSetup: Bool {
        if case .notReady = latestSnapshot.phase { return true }
        return !defaults.bool(forKey: onboardingCompleteKey)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard onboarding.window?.isVisible == true || settings.window?.isVisible == true else { return }
        // Login-item approval can change while the user is in System Settings.
        updateLaunchAtLogin()
        updateOnboarding(message: runtimeMessage ?? latestSnapshot.message)
    }

    func applicationWillTerminate(_ notification: Notification) {
        observationTask?.cancel()
        modelObservationTask?.cancel()
        grammarObservationTask?.cancel()
        focusObservationTask?.cancel()
        triggerPreparationTask?.cancel()
        statusTimer?.invalidate()
        inputDeviceObserver.stop()
        triggerMonitor.stop()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu(menu, snapshot: latestSnapshot)
    }

    func configureApplicationMenu() {
        // Accessory apps still need standard editing commands: dictation delivers
        // to native text areas through the same Command-V path as manual paste.
        let menu = NSMenu()
        let application = NSMenuItem()
        let applicationMenu = NSMenu(title: "VoxKey")
        applicationMenu.addItem(withTitle: "Quit VoxKey", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        application.submenu = applicationMenu
        menu.addItem(application)

        let edit = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = editMenu
        menu.addItem(edit)
        NSApp.mainMenu = menu
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = VoxKeyDesign.menuBarMark()
        item.button?.imagePosition = .imageOnly
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        rebuildMenu(menu, snapshot: latestSnapshot)
    }

    func rebuildMenu(_ menu: NSMenu, snapshot: SessionSnapshot) {
        menu.removeAllItems()
        let status = NSMenuItem(title: statusTitle(for: snapshot), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        if snapshot.lastResult != nil, !snapshot.phase.isBusy {
            let safety = NSMenuItem(title: "Recover Dictation…", action: #selector(openSafetyNet), keyEquivalent: "")
            safety.target = self
            menu.addItem(safety)
        }

        if needsSetup {
            let setup = NSMenuItem(title: "Set Up VoxKey…", action: #selector(openOnboarding), keyEquivalent: "")
            setup.target = self
            menu.addItem(setup)
        }

        let preferences = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        preferences.target = self
        menu.addItem(preferences)

        let models = NSMenuItem(title: "Models and Languages…", action: #selector(openModelSettings), keyEquivalent: "")
        models.target = self
        menu.addItem(models)

        let vocabulary = NSMenuItem(title: "Vocabulary…", action: #selector(openVocabulary), keyEquivalent: "")
        if case .failure = vocabularyStore { vocabulary.title = "Vocabulary Needs Attention…" }
        vocabulary.target = self
        menu.addItem(vocabulary)

        let cues = NSMenuItem(title: "Capture Sounds", action: #selector(toggleCues), keyEquivalent: "")
        cues.target = self
        cues.toolTip = "Play sounds before listening and after the microphone closes. Turn off for silent dictation; the status overlay stays visible."
        cues.state = cuePlayer.enabled ? .on : .off
        menu.addItem(cues)

        menu.addItem(.separator())
        updates.addMenuItems(to: menu)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit VoxKey", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func statusTitle(for snapshot: SessionSnapshot) -> String {
        switch snapshot.phase {
        case .ready: "Ready — \(captureMode == .hold ? "hold" : "press") \(triggerMonitor.trigger.displayName) to dictate"
        case .arming: "Starting capture…"
        case .capturing: "Listening…"
        case .finalizing: snapshot.message == "Correcting grammar…" ? "Correcting grammar…" : "Transcribing…"
        case .delivering: "Delivering…"
        case let .notReady(reason):
            switch reason {
            case .onboarding: "Setup required"
            case .microphonePermission: "Microphone access required"
            case .accessibilityPermission: "Accessibility access required"
            case .modelUnavailable: "Transcription model required"
            }
        }
    }

    private func configureWindows() {
        onboarding.onChooseModel = { [weak self] in self?.openModelSettings() }
        settings.onChooseModel = { [weak self] in self?.openModelSettings() }
        updateGrammarLanguage()
        let grammarEnabled = defaults.bool(forKey: GrammarCorrector.preferenceKey) && GrammarCorrector.isAvailable
        updateGrammarCorrection(enabled: grammarEnabled, state: grammarEnabled ? .waiting : .off)
        applyGrammarPreference(grammarEnabled)
        // Setup and Settings each show a grammar card; a change in one is mirrored to the other.
        let grammarChanged: (Bool) -> Void = { [weak self] enabled in
            guard let self else { return }
            defaults.set(enabled, forKey: GrammarCorrector.preferenceKey)
            updateGrammarCorrection(enabled: enabled, state: enabled ? .waiting : .off)
            applyGrammarPreference(enabled, download: enabled)
        }
        onboarding.onGrammarCorrectionChanged = grammarChanged
        settings.onGrammarCorrectionChanged = grammarChanged
        let prepareGrammar: () -> Void = { [weak self] in
            self?.updateGrammarCorrection(enabled: true, state: .downloading(0))
            self?.applyGrammarPreference(true, download: true, repair: true)
        }
        onboarding.onPrepareGrammarModel = prepareGrammar
        settings.onPrepareGrammarModel = prepareGrammar
        grammarObservationTask = Task { [weak self] in
            guard let self else { return }
            for await state in coordinator.grammarUpdates {
                guard !Task.isCancelled else { return }
                updateGrammarCorrection(
                    enabled: defaults.bool(forKey: GrammarCorrector.preferenceKey) && GrammarCorrector.isAvailable,
                    state: state)
            }
        }
        inputDeviceObserver.onChange = { [weak self] catalog in
            guard let self else { return }
            inputCatalog = catalog
            settings.updateMicrophones(catalog, pinnedUID: defaults.string(forKey: microphoneUIDKey))
        }
        settings.onMicrophoneChanged = { [weak self] uid in
            guard let self else { return }
            defaults.set(uid, forKey: microphoneUIDKey)
            settings.updateMicrophones(inputCatalog, pinnedUID: uid)
        }
        inputDeviceObserver.start()
        settings.updateCaptureMode(captureMode)
        onboarding.updateCaptureMode(captureMode)
        settings.onCaptureModeChanged = { [weak self] mode in
            guard let self else { return }
            defaults.set(mode == .toggle, forKey: "VoxKeyToggleDictation")
            onboarding.updateCaptureMode(mode)
        }
        settings.onLaunchAtLoginChanged = { [weak self] enabled in
            self?.setLaunchAtLogin(enabled)
        }
        settings.updateTrigger(triggerMonitor.trigger)
        onboarding.updateTrigger(triggerMonitor.trigger)
        settings.onTriggerChanged = { [weak self] trigger in
            guard let self else { return }
            defaults.set(trigger.rawValue, forKey: triggerKey)
            triggerMonitor.trigger = trigger
            onboarding.updateTrigger(trigger)
        }
        onboarding.onRequestMicrophone = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                _ = await AudioCaptureService.requestMicrophonePermission()
                await coordinator.refreshReadiness()
                await refreshRuntimeState()
                presentOnboarding()
            }
        }
        onboarding.onRequestAccessibility = { [weak self] in
            _ = AccessibilityService.requestTrust()
            self?.runtimeMessage = "Grant VoxKey access in System Settings, then return here."
        }
        onboarding.onFinish = { [weak self] in
            self?.completeOnboarding()
        }
    }

    private func updateGrammarCorrection(enabled: Bool, state: GrammarCorrectionState) {
        onboarding.updateGrammarCorrection(enabled: enabled, state: state)
        settings.updateGrammarCorrection(enabled: enabled, state: state)
    }

    private func updateGrammarLanguage() {
        let supported = transcriptionConfiguration.supportsGrammarCorrection
        onboarding.grammar.updateLanguage(supported: supported)
        settings.grammar.updateLanguage(supported: supported)
    }

    private func applyGrammarPreference(_ enabled: Bool, download: Bool = false, repair: Bool = false) {
        let previous = grammarPreferenceTask
        grammarPreferenceTask = Task {
            await previous?.value
            let allowed = enabled && transcriptionConfiguration.supportsGrammarCorrection
            await coordinator.setGrammarCorrectionEnabled(allowed, download: allowed && download, repair: repair)
        }
    }

    private func observeCoordinator() {
        observationTask = Task { [weak self] in
            guard let self else { return }
            for await snapshot in coordinator.updates {
                guard !Task.isCancelled else { return }
                let stateChanged = latestSnapshot.phase != snapshot.phase || latestSnapshot.message != snapshot.message
                    || latestSnapshot.attention != snapshot.attention || latestSnapshot.lastResult != snapshot.lastResult
                latestSnapshot = snapshot
                updateModelSettings()
                overlay.update(snapshot)
                guard stateChanged else { continue }
                updates.installation.update(snapshot)
                if let result = snapshot.lastResult {
                    safetyNet?.updateResult(result)
                } else {
                    safetyNet?.closeAfterResolution()
                    safetyNet = nil
                }
                presentDictationIfNeeded(snapshot)
                updateStatusIcon(snapshot)
                updateOnboarding(message: snapshot.message)

                if readinessCheckInFlight, snapshot.message == "Delivered", !onboarding.testTextView.string.isEmpty {
                    readinessCheckInFlight = false
                    onboarding.markComplete()
                } else if !snapshot.phase.isBusy, snapshot.message != "Delivered" {
                    readinessCheckInFlight = false
                }
            }
        }
    }

    private func observeModelPreparation() {
        modelObservationTask = Task { [weak self] in
            guard let self else { return }
            for await phase in coordinator.modelUpdates {
                guard !Task.isCancelled else { return }
                modelPhase = phase
                switch phase {
                case .required:
                    break
                case let .downloading(fraction):
                    let percentage = Int((min(max(fraction, 0), 1) * 100).rounded())
                    runtimeMessage = "Downloading the model… \(percentage)%"
                case .prewarming:
                    runtimeMessage = "Download complete. Optimizing the model for this Mac…"
                case .ready:
                    runtimeMessage = nil
                case .failed:
                    runtimeMessage = "Model preparation failed. Resume preparation to reuse completed downloads."
                }
                updateOnboarding(message: runtimeMessage)
                updateModelSettings()
            }
        }
    }

    private func updateStatusIcon(_ snapshot: SessionSnapshot) {
        let symbol: String
        switch snapshot.phase {
        case .ready where snapshot.lastResult?.failure == nil:
            let mark = VoxKeyDesign.menuBarMark()
            mark.accessibilityDescription = statusTitle(for: snapshot)
            statusItem?.button?.image = mark
            return
        case .ready: symbol = "exclamationmark.bubble.fill"
        case .capturing: symbol = "mic.fill"
        case .arming, .finalizing, .delivering: symbol = "ellipsis.circle"
        case .notReady: symbol = "waveform.badge.exclamationmark"
        }
        statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: statusTitle(for: snapshot))
    }

    private func refreshRuntimeState() async {
        if settings.window?.isVisible == true {
            settings.updateMicrophoneFallback(await coordinator.microphoneFallbackUsed())
        }
        if latestSnapshot.phase.isBusy {
            await coordinator.enforceCaptureSafety()
            let snapshot = await coordinator.currentSnapshot()
            latestSnapshot = snapshot
            overlay.update(snapshot)
            return
        }

        await coordinator.refreshReadiness()
        if AccessibilityService.isTrusted, !triggerStarted {
            do {
                try triggerMonitor.start()
                triggerMonitor.onPress = { [weak self] in self?.handleTriggerPress() }
                triggerMonitor.onRelease = { [weak self] in self?.handleTriggerRelease() }
                triggerMonitor.onCancel = { [weak self] in self?.handleCancel() }
                triggerMonitor.onFocusSignal = { [weak self] in self?.handleFocusSignal() }
                triggerStarted = true
                runtimeMessage = nil
            } catch {
                runtimeMessage = "The \(triggerMonitor.trigger.displayName) trigger is unavailable. Check Accessibility access in System Settings."
            }
        } else if !AccessibilityService.isTrusted, triggerStarted {
            triggerMonitor.stop()
            triggerStarted = false
        }
        updateOnboarding(message: runtimeMessage ?? latestSnapshot.message)
    }

    private func handleTriggerPress() {
        if latestSnapshot.phase.isBusy {
            Task { await coordinator.triggerPressed() }
            return
        }
        readinessCheckInFlight = onboarding.isTestFieldFocused
        let vocabulary = (try? vocabularyStore.get())?.recognitionTerms ?? []
        let focusObservationTask = focusObservationTask
        let captureMode = captureMode
        let trigger = triggerMonitor.trigger
        let microphoneUID = defaults.string(forKey: microphoneUIDKey)
        let preparation = Task { @MainActor in
            await focusObservationTask?.value
            await grammarPreferenceTask?.value
            return await coordinator.triggerPressed(vocabulary: vocabulary, captureMode: captureMode, trigger: trigger, microphoneUID: microphoneUID)
        }
        triggerPreparationTask = preparation
        Task { @MainActor in
            guard let sessionID = await preparation.value else {
                readinessCheckInFlight = false
                return
            }
            await coordinator.startCapture(sessionID: sessionID)
        }
    }

    private func handleFocusSignal() {
        focusSignalGeneration &+= 1
        let generation = focusSignalGeneration
        focusObservationTask = Task { [weak self] in
            guard let self else { return }
            await coordinator.observePotentialFocus(generation: generation)
        }
    }

    private func handleTriggerRelease() {
        let preparation = triggerPreparationTask
        Task {
            guard let sessionID = await preparation?.value else { return }
            await coordinator.triggerReleased(sessionID: sessionID)
        }
    }

    private func handleCancel() {
        let preparation = triggerPreparationTask
        Task {
            guard let sessionID = await preparation?.value else { return }
            await coordinator.cancel(expectedSessionID: sessionID)
        }
    }

    private func prepareModel(download: Bool, selection: TranscriptionConfiguration? = nil) async {
        guard !modelPreparationTaskActive, !latestSnapshot.phase.isBusy else {
            modelSelectionMessage = "Finish the current dictation before changing models."
            updateModelSettings()
            return
        }
        switch modelPhase {
        case .downloading, .prewarming:
            return
        case .required, .ready, .failed:
            break
        }
        modelPreparationTaskActive = true
        modelSelectionMessage = nil
        let configuration = selection ?? transcriptionConfiguration
        preparingModel = configuration.model
        defer { modelPreparationTaskActive = false; preparingModel = nil; updateModelSettings() }
        runtimeMessage = download ? "Downloading and preparing the model. This can take several minutes…" : nil
        updateModelSettings()
        updateOnboarding(message: runtimeMessage)
        do {
            do {
                try await coordinator.prepareModel(configuration, download: false)
            } catch TranscriptionError.modelNotInstalled where download {
                try await coordinator.prepareModel(configuration, download: true)
            }
            configuration.save(to: defaults)
            activeModelReady = true
            defaults.set(true, forKey: modelInstalledKey)
            updateGrammarLanguage()
            applyGrammarPreference(defaults.bool(forKey: GrammarCorrector.preferenceKey) && GrammarCorrector.isAvailable)
            modelSelectionMessage = "Ready. Your selection will be used for the next dictation."
        } catch {
            defaults.set(activeModelReady, forKey: modelInstalledKey)
            modelSelectionMessage = activeModelReady
                ? "Could not prepare this model. Your previous model and language are still active. Try again to resume the download."
                : "Could not prepare this model. Try again to resume the download."
            if !download, !activeModelReady {
                modelPhase = .required
                runtimeMessage = "The installed model is unavailable. Prepare it again."
            }
            await coordinator.refreshReadiness()
        }
        installedModels = await modelLibrary.installedModels()
        updateOnboarding(message: runtimeMessage ?? latestSnapshot.message)
    }

    private func updateModelSettings() {
        let configuration = transcriptionConfiguration
        settings.modelSummary.stringValue = activeModelReady
            ? "\(configuration.model.name) · \(TranscriptionModel.languageName(configuration.language))"
            : "Download a model and choose which one to use."
        modelSettings?.update(active: configuration, ready: activeModelReady, installed: installedModels,
                              busy: modelPreparationTaskActive || latestSnapshot.phase.isBusy,
                              downloading: downloadingModel, downloadProgress: modelDownloadProgress,
                              preparing: preparingModel, message: modelSelectionMessage)
    }

    @objc private func openModelSettings() {
        if modelSettings == nil {
            let controller = ModelSettingsWindowController()
            controller.onActivate = { [weak self] configuration in
                Task { @MainActor in await self?.prepareModel(download: false, selection: configuration) }
            }
            controller.onDownload = { [weak self] model in self?.downloadModel(model) }
            modelSettings = controller
        }
        updateModelSettings()
        modelSettings?.present()
        Task {
            installedModels = await modelLibrary.installedModels()
            updateModelSettings()
        }
    }

    private func downloadModel(_ model: TranscriptionModel) {
        guard downloadingModel == nil, !modelPreparationTaskActive else { return }
        downloadingModel = model
        modelDownloadProgress = 0
        modelSelectionMessage = nil
        updateModelSettings()
        Task {
            do {
                try await modelLibrary.download(model) { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, self.downloadingModel == model else { return }
                        self.modelDownloadProgress = fraction
                        self.updateModelSettings()
                    }
                }
                modelSelectionMessage = "\(model.name) is downloaded. Choose Use Model when you want to activate it."
            } catch {
                modelSelectionMessage = "Could not download \(model.name). Try again to reuse completed files. Your active model is unchanged."
            }
            installedModels = await modelLibrary.installedModels()
            downloadingModel = nil
            updateModelSettings()
        }
    }

    func updateOnboarding(message: String?, force: Bool = false) {
        guard force || onboarding.window?.isVisible == true else { return }
        let status = OnboardingStatus(
            microphone: AudioCaptureService.microphoneAuthorized(),
            accessibility: AccessibilityService.isTrusted,
            modelPhase: modelPhase,
            message: runtimeMessage ?? message
        )
        guard force || status != renderedOnboardingStatus else { return }
        renderedOnboardingStatus = status
        onboarding.update(microphone: status.microphone, accessibility: status.accessibility,
                          modelPhase: status.modelPhase, message: status.message)
    }

    func presentLaunchOnboardingIfNeeded(microphoneAuthorized: Bool, accessibilityTrusted: Bool) {
        guard !hasPresentedOnboarding else { return }
        guard !defaults.bool(forKey: onboardingCompleteKey)
                || !microphoneAuthorized || !accessibilityTrusted
                || !defaults.bool(forKey: modelInstalledKey) else { return }
        presentOnboarding()
    }

    private func presentOnboarding() {
        hasPresentedOnboarding = true
        updateLaunchAtLogin()
        updateOnboarding(message: runtimeMessage ?? latestSnapshot.message, force: true)
        // Keep a way back to setup while system permission dialogs take focus,
        // including when a previously completed install needs permissions again.
        let showsInDock = NSApp.setActivationPolicy(.regular)
        statusItem?.isVisible = !showsInDock
        onboarding.present()
    }

    private func finishOnboardingPresentation() {
        statusItem?.isVisible = true
        NSApp.setActivationPolicy(.accessory)
    }

    private func completeOnboarding() {
        readinessCheckInFlight = false
        defaults.set(true, forKey: onboardingCompleteKey)
        if SMAppService.mainApp.status == .notRegistered {
            try? SMAppService.mainApp.register()
        }
        onboarding.resetCompletionState()
        onboarding.close()
    }

    @objc private func openSafetyNet() {
        Task { @MainActor in
            guard let result = await coordinator.lastResult() else { return }
            let destination = await coordinator.prepareRecoveryDestination(for: result.id)
            guard let current = await coordinator.lastResult(), current.id == result.id else { return }
            presentSafetyNet(result: current, destination: destination)
        }
    }

    func presentDictationIfNeeded(_ snapshot: SessionSnapshot) {
        guard snapshot.phase == .ready, snapshot.attention == .dictationReady,
              let result = snapshot.lastResult else { return }
        // Capture had no input. Show the text without selecting a new destination
        // merely because focus may have changed while transcription completed.
        presentSafetyNet(result: result, destination: nil)
    }

    private func presentSafetyNet(result current: LastResult, destination: DestinationLabel?) {
        if let safetyNet {
            safetyNet.updateResult(current)
            safetyNet.updateDestination(destination)
            safetyNet.present()
            return
        }
        let controller = SafetyNetWindowController(result: current, destination: destination)
        controller.onDeliver = { [weak self, weak controller] result in
            guard let self else { return }
            Task { @MainActor in
                let outcome = await coordinator.deliverLastResult(id: result.id)
                controller?.setDeliveryInFlight(false)
                if outcome == .delivered || outcome == .unconfirmed {
                    controller?.closeAfterResolution()
                    safetyNet = nil
                } else {
                    if let current = await coordinator.lastResult() { controller?.updateResult(current) }
                    controller?.updateDestination(nil)
                    controller?.present()
                }
            }
        }
        controller.onCopy = { [weak self, weak controller] result in
            guard let self else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(result.text, forType: .string)
            Task { await coordinator.clearLastResult(id: result.id) }
            controller?.closeAfterResolution()
            safetyNet = nil
        }
        controller.onDismiss = { [weak self] resultID in
            guard let self else { return }
            Task { await coordinator.clearLastResult(id: resultID) }
            safetyNet = nil
        }
        safetyNet = controller
        controller.present()
    }

    @objc private func openOnboarding() {
        presentOnboarding()
        updateOnboarding(message: runtimeMessage ?? latestSnapshot.message)
    }

    @objc private func openSettings() {
        updateLaunchAtLogin()
        settings.present()
    }

    @objc private func openVocabulary() {
        do {
            let store = try vocabularyStore.get()
            if vocabularyWindow == nil { vocabularyWindow = VocabularyWindowController(store: store) }
            vocabularyWindow?.present()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Vocabulary couldn’t be loaded"
            alert.informativeText = VocabularyError.unreadableStorage.localizedDescription
            alert.runModal()
        }
    }

    @objc private func toggleCues() {
        cuePlayer.enabled.toggle()
        defaults.set(cuePlayer.enabled, forKey: cuesEnabledKey)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLoginError = "Launch at Login could not be changed. Try again."
        }
        updateLaunchAtLogin()
    }

    private func updateLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        settings.updateLaunchAtLogin(
            enabled: status == .enabled,
            message: launchAtLoginError ?? (status == .requiresApproval
                ? "Allow VoxKey in System Settings → General → Login Items & Extensions."
                : nil)
        )
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
