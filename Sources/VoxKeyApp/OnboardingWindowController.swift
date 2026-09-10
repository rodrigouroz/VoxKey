import AppKit
import VoxKeyCore

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    var onRequestMicrophone: (() -> Void)?
    var onRequestAccessibility: (() -> Void)?
    var onPrepareModel: (() -> Void)?
    var onFinish: (() -> Void)?
    var onClose: (() -> Void)?
    var onMicrophoneChanged: ((String?) -> Void)?
    let microphonePopup = NSPopUpButton()
    private let microphoneNote = VoxKeyDesign.label("", style: .caption, color: VoxKeyDesign.secondaryInk)
    private var microphoneUIDs: [String?] = []
    private var pinnedMicrophoneMissing = false
    var onCaptureModeChanged: ((CaptureMode) -> Void)?
    private var captureMode: CaptureMode = .hold
    let toggleCheckbox = NSButton(checkboxWithTitle: "Toggle Dictation", target: nil, action: nil)
    var onLaunchAtLoginChanged: ((Bool) -> Void)?
    let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch at Login", target: nil, action: nil)
    private let launchAtLoginNote = VoxKeyDesign.label("Start VoxKey automatically when you log in.", style: .caption, color: VoxKeyDesign.secondaryInk)
    private let gestureHint = VoxKeyDesign.label("hold to speak", style: .footnote, color: VoxKeyDesign.secondaryInk)
    var onTriggerChanged: ((DictationTrigger) -> Void)?
    private(set) var dictationTrigger: DictationTrigger = .globe
    let triggerPopup = NSPopUpButton()
    private let triggerHint = VoxKeyDesign.label("", style: .caption, color: VoxKeyDesign.secondaryInk)
    private let triggerKeyLabel = VoxKeyDesign.label("Globe/Fn", style: .micro, color: VoxKeyDesign.secondaryInk)
    private let tabs = NSTabView()
    let preferencesStack = NSStackView()
    var onGrammarCorrectionChanged: ((Bool) -> Void)?
    var onPrepareGrammarModel: (() -> Void)?
    private let grammarDownloadButton = NSButton(title: "Download Grammar Model", target: nil, action: nil)
    private let setupGrammarDownloadButton = NSButton(title: "Download Grammar Model", target: nil, action: nil)
    let grammarCheckbox = NSButton(checkboxWithTitle: "Correct grammar locally", target: nil, action: nil)
    let setupGrammarCheckbox = NSButton(checkboxWithTitle: "Correct grammar locally (optional)", target: nil, action: nil)
    private let grammarStatus = VoxKeyDesign.label("Off. No extra processing.", style: .caption, color: VoxKeyDesign.secondaryInk)
    private let setupGrammarStatus = VoxKeyDesign.label("Off. No extra processing.", style: .caption, color: VoxKeyDesign.secondaryInk)


    private let microphoneStatus = NSTextField(labelWithString: "Microphone")
    private let accessibilityStatus = NSTextField(labelWithString: "Accessibility")
    private let modelStatus = NSTextField(labelWithString: "English model")
    private let microphoneIndicator = NSTextField(labelWithString: "01")
    private let accessibilityIndicator = NSTextField(labelWithString: "02")
    private let modelIndicator = NSTextField(labelWithString: "03")
    private let microphoneState = NSTextField(labelWithString: "")
    private let accessibilityState = NSTextField(labelWithString: "")
    private let modelState = NSTextField(labelWithString: "")
    private let modelProgress = NSProgressIndicator()
    private let messageLabel = VoxKeyDesign.label("", style: .caption, color: VoxKeyDesign.secondaryInk)
    private let microphoneButton = NSButton(title: "Continue", target: nil, action: nil)
    private let accessibilityButton = NSButton(title: "Open System Settings", target: nil, action: nil)
    private let modelButton = NSButton(title: "Prepare English Model", target: nil, action: nil)
    private let finishButton = NSButton(title: "Finish Setup", target: nil, action: nil)
    private static let readinessPrompt = "When the checks are ready, click below. Hold Globe/Fn, say a sentence, and release to see your words arrive."
    private let readinessInstructions = VoxKeyDesign.label(OnboardingWindowController.readinessPrompt, style: .caption, color: VoxKeyDesign.secondaryInk)
    private let readinessTitle = VoxKeyDesign.label("Give it a first word.", style: .sectionTitle)
    private let readinessState = VoxKeyDesign.eyebrow("READINESS CHECK")
    private let readinessCard = VoxKeyCardView()
    private let activationCoordinator: ApplicationActivationCoordinator
    private var isComplete = false
    let testTextView = NSTextView()

    init(activationCoordinator: ApplicationActivationCoordinator = ApplicationActivationCoordinator(), grammarAvailable: Bool = GrammarCorrector.isAvailable) {
        self.activationCoordinator = activationCoordinator
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 656, height: grammarAvailable ? 820 : 700),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Set Up VoxKey"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self

        microphoneButton.target = self
        microphoneButton.action = #selector(requestMicrophone)
        accessibilityButton.target = self
        accessibilityButton.action = #selector(requestAccessibility)
        modelButton.target = self
        modelButton.action = #selector(prepareModel)
        finishButton.target = self
        finishButton.action = #selector(finishSetup)
        finishButton.keyEquivalent = "\r"
        finishButton.isHidden = true
        for button in [microphoneButton, accessibilityButton, modelButton, finishButton] {
            VoxKeyDesign.configureButton(button, primary: true)
        }

        let brandRow = VoxKeyDesign.brandRow()

        let title = VoxKeyDesign.label("Press. Speak.\nRelease.", style: .onboardingHero)
        let subtitle = VoxKeyDesign.label(
            "VoxKey transcribes entirely on this Mac and safely inserts the final text into the field you chose.",
            color: VoxKeyDesign.secondaryInk
        )
        let heroCopy = vertical([title, subtitle], spacing: 10)
        let mark = VoxKeyBrandMarkView(size: 118)
        let hero = horizontal([heroCopy, NSView(), mark], spacing: 28)
        subtitle.widthAnchor.constraint(equalToConstant: 404).isActive = true
        heroCopy.widthAnchor.constraint(equalToConstant: 404).isActive = true

        modelProgress.style = .bar
        modelProgress.controlSize = .small
        modelProgress.minValue = 0
        modelProgress.maxValue = 1
        modelProgress.isHidden = true
        modelProgress.setAccessibilityLabel("English model preparation progress")

        let permissionCard = VoxKeyCardView()
        let permissionRows = vertical([
            permissionRow(status: microphoneStatus, indicator: microphoneIndicator, state: microphoneState, button: microphoneButton),
            separator(),
            permissionRow(status: accessibilityStatus, indicator: accessibilityIndicator, state: accessibilityState, button: accessibilityButton),
            separator(),
            permissionRow(status: modelStatus, indicator: modelIndicator, state: modelState, button: modelButton)
        ], spacing: 0)
        embed(permissionRows, in: permissionCard, inset: NSEdgeInsets(top: 5, left: 16, bottom: 5, right: 16))
        let setupHeading = horizontal([
            VoxKeyDesign.eyebrow("01 / A LITTLE SETUP"),
            NSView(),
            VoxKeyDesign.label("Three checks. Then you’re in.", style: .footnote, color: VoxKeyDesign.secondaryInk)
        ], spacing: 8)
        let prerequisites = vertical([setupHeading, permissionCard, modelProgress], spacing: 10)
        permissionCard.widthAnchor.constraint(equalTo: prerequisites.widthAnchor).isActive = true
        modelProgress.widthAnchor.constraint(equalTo: prerequisites.widthAnchor).isActive = true
        setupHeading.widthAnchor.constraint(equalTo: prerequisites.widthAnchor).isActive = true

        let checkHeading = horizontal([readinessTitle, NSView(), readinessState], spacing: 12)
        let instructions = readinessInstructions
        testTextView.string = ""
        testTextView.minSize = NSSize(width: 0, height: 84)
        testTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        testTextView.isHorizontallyResizable = false
        testTextView.isVerticallyResizable = true
        testTextView.autoresizingMask = [.width]
        testTextView.textContainer?.widthTracksTextView = true
        testTextView.setAccessibilityLabel("Readiness check dictation field")
        testTextView.setAccessibilityHelp("Hold Globe or Fn, say a sentence, and release. Your first dictation must be delivered here to finish setup.")
        testTextView.frame = NSRect(x: 0, y: 0, width: 560, height: 84)
        let fieldBorder = VoxKeyDesign.textField(testTextView, minimumHeight: 86)
        fieldBorder.heightAnchor.constraint(equalToConstant: 86).isActive = true
        let keyHint = horizontal([
            triggerKeyLabel,
            gestureHint,
            NSView(),
            VoxKeyDesign.label("Esc to cancel", style: .footnote, color: VoxKeyDesign.secondaryInk)
        ], spacing: 6)
        let checkContent = vertical([checkHeading, instructions, fieldBorder, keyHint], spacing: VoxKeyDesign.Layout.contentSpacing)
        VoxKeyDesign.embed(checkContent, in: readinessCard)
        for view in [checkHeading, instructions, fieldBorder, keyHint] {
            view.widthAnchor.constraint(equalTo: checkContent.widthAnchor).isActive = true
        }

        messageLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let completionActions = horizontal([messageLabel, NSView(), finishButton], spacing: 16)
        completionActions.heightAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
        let setupGrammar = grammarCard(checkbox: setupGrammarCheckbox, status: setupGrammarStatus, download: setupGrammarDownloadButton)
        setupGrammar.isHidden = !grammarAvailable
        let stack = vertical([brandRow, hero, prerequisites, setupGrammar, readinessCard, completionActions], spacing: VoxKeyDesign.Layout.sectionSpacing)
        VoxKeyDesign.install(stack, in: window)
        for view in [brandRow, hero, prerequisites, setupGrammar, readinessCard, completionActions] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let readinessView = window.contentView!
        let readinessTab = NSTabViewItem(identifier: "readiness")
        readinessTab.label = "Readiness"
        readinessTab.view = readinessView
        let settingsTab = NSTabViewItem(identifier: "settings")
        settingsTab.label = "Settings"
        let settingsView = VoxKeyCardView(fill: VoxKeyDesign.canvas, border: .clear, cornerRadius: 0)
        preferencesStack.orientation = .vertical
        preferencesStack.alignment = .leading
        preferencesStack.spacing = 16
        preferencesStack.addArrangedSubview(VoxKeyDesign.label("Make it yours.", style: .sectionTitle))
        triggerPopup.addItems(withTitles: DictationTrigger.allCases.map(\.displayName))
        triggerPopup.setAccessibilityLabel("Dictation trigger")
        triggerPopup.target = self
        triggerPopup.action = #selector(changeTrigger)
        let triggerRow = vertical([VoxKeyDesign.label("Dictation trigger"), triggerPopup, triggerHint], spacing: 8)
        let triggerCard = VoxKeyCardView()
        VoxKeyDesign.embed(triggerRow, in: triggerCard)
        preferencesStack.addArrangedSubview(triggerCard)
        triggerCard.widthAnchor.constraint(equalTo: preferencesStack.widthAnchor).isActive = true
        preferencesStack.translatesAutoresizingMaskIntoConstraints = false
        settingsView.addSubview(preferencesStack)
        NSLayoutConstraint.activate([
            preferencesStack.topAnchor.constraint(equalTo: settingsView.topAnchor, constant: 24),
            preferencesStack.leadingAnchor.constraint(equalTo: settingsView.leadingAnchor, constant: 28),
            preferencesStack.trailingAnchor.constraint(equalTo: settingsView.trailingAnchor, constant: -28)
        ])
        toggleCheckbox.target = self
        toggleCheckbox.action = #selector(changeCaptureMode)
        let toggleCard = VoxKeyCardView()
        let toggleContent = vertical([toggleCheckbox, VoxKeyDesign.label(
            "Press once to start, again to finish. Off: hold the trigger while speaking.",
            style: .caption, color: VoxKeyDesign.secondaryInk)], spacing: 8)
        VoxKeyDesign.embed(toggleContent, in: toggleCard)
        preferencesStack.addArrangedSubview(toggleCard)
        toggleCard.widthAnchor.constraint(equalTo: preferencesStack.widthAnchor).isActive = true
        microphonePopup.setAccessibilityLabel("Microphone")
        microphonePopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        microphonePopup.cell?.lineBreakMode = .byTruncatingMiddle
        microphonePopup.target = self
        microphonePopup.action = #selector(changeMicrophone)
        let microphoneCard = VoxKeyCardView()
        VoxKeyDesign.embed(vertical([VoxKeyDesign.label("Microphone"), microphonePopup, microphoneNote], spacing: 8), in: microphoneCard)
        preferencesStack.addArrangedSubview(microphoneCard)
        microphoneCard.widthAnchor.constraint(equalTo: preferencesStack.widthAnchor).isActive = true
        microphonePopup.widthAnchor.constraint(lessThanOrEqualTo: microphoneCard.widthAnchor, constant: -36).isActive = true
        let grammarSettings = grammarCard(checkbox: grammarCheckbox, status: grammarStatus, download: grammarDownloadButton)
        grammarSettings.isHidden = !grammarAvailable
        preferencesStack.addArrangedSubview(grammarSettings)
        grammarSettings.widthAnchor.constraint(equalTo: preferencesStack.widthAnchor).isActive = true
        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(changeLaunchAtLogin)
        let loginCard = VoxKeyCardView()
        VoxKeyDesign.embed(vertical([launchAtLoginCheckbox, launchAtLoginNote], spacing: 8), in: loginCard)
        preferencesStack.addArrangedSubview(loginCard)
        loginCard.widthAnchor.constraint(equalTo: preferencesStack.widthAnchor).isActive = true
        let feedbackButton = NSButton(title: "Send Feedback…", target: self, action: #selector(openFeedback))
        VoxKeyDesign.configureButton(feedbackButton)
        feedbackButton.setAccessibilityHelp("Open GitHub to report a bug or suggest a feature.")
        let feedbackRow = horizontal([
            VoxKeyDesign.label("Bugs or ideas? Share them on GitHub.", style: .caption, color: VoxKeyDesign.secondaryInk),
            NSView(),
            feedbackButton
        ], spacing: 12)
        preferencesStack.addArrangedSubview(feedbackRow)
        feedbackRow.widthAnchor.constraint(equalTo: preferencesStack.widthAnchor).isActive = true
        updateMicrophones(AudioInputCatalog(), pinnedUID: nil)
        settingsTab.view = settingsView
        tabs.addTabViewItem(readinessTab)
        tabs.addTabViewItem(settingsTab)
        window.contentView = tabs
        updateTrigger(.globe)
        update(microphone: false, accessibility: false, modelPhase: .required, message: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateMicrophones(_ catalog: AudioInputCatalog, pinnedUID: String?) {
        microphonePopup.removeAllItems()
        microphonePopup.addItem(withTitle: "System default (\(catalog.defaultName))")
        microphoneUIDs = [nil]
        // Popup convenience methods replace duplicate titles; menu items preserve devices
        // that happen to share a display name.
        for device in catalog.devices {
            microphonePopup.menu?.addItem(NSMenuItem(title: device.name, action: nil, keyEquivalent: ""))
            microphoneUIDs.append(device.uid)
        }
        pinnedMicrophoneMissing = catalog.selection(for: pinnedUID).usedDefaultFallback
        if pinnedMicrophoneMissing {
            microphonePopup.addItem(withTitle: "Pinned microphone (unavailable)")
            microphoneUIDs.append(pinnedUID)
        }
        microphonePopup.selectItem(at: microphoneUIDs.firstIndex { $0 == pinnedUID } ?? 0)
        updateMicrophoneFallback(false)
    }

    func updateMicrophoneFallback(_ usedFallback: Bool) {
        microphoneNote.stringValue = pinnedMicrophoneMissing || usedFallback
            ? "The pinned microphone was unavailable. VoxKey uses the system default for that dictation."
            : "Changes apply to the next dictation. An active capture keeps its microphone."
    }

    @objc private func changeMicrophone() {
        guard microphoneUIDs.indices.contains(microphonePopup.indexOfSelectedItem) else { return }
        onMicrophoneChanged?(microphoneUIDs[microphonePopup.indexOfSelectedItem])
    }

    func showSettings() { tabs.selectTabViewItem(withIdentifier: "settings") }

    @objc private func openFeedback() {
        guard let url = URL(string: "https://github.com/rodrigouroz/VoxKey/issues/new/choose") else { return }
        NSWorkspace.shared.open(url)
    }

    private func grammarCard(checkbox: NSButton, status: NSTextField, download: NSButton) -> NSView {
        checkbox.target = self
        checkbox.action = #selector(changeGrammarCorrection(_:))
        let explanation = VoxKeyDesign.label(
            "Fix basic English grammar locally. Correction starts while you dictate. Adds processing and may change words.",
            style: .caption, color: VoxKeyDesign.secondaryInk)
        let terms = VoxKeyDesign.label("519 MB download when enabled · Model for noncommercial use only", style: .caption, color: VoxKeyDesign.secondaryInk)
        download.target = self
        download.action = #selector(prepareGrammarModel)
        download.isHidden = true
        let statusRow = horizontal([status, NSView(), download], spacing: 8)
        let content = vertical([checkbox, explanation, statusRow, terms], spacing: 6)
        let card = VoxKeyCardView()
        VoxKeyDesign.embed(content, in: card)
        for view in [explanation, statusRow, terms] { view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        return card
    }

    func updateGrammarCorrection(enabled: Bool, state: GrammarCorrectionState) {
        grammarCheckbox.state = enabled ? .on : .off
        setupGrammarCheckbox.state = grammarCheckbox.state
        grammarStatus.stringValue = state.message
        setupGrammarStatus.stringValue = state.message
        for button in [grammarDownloadButton, setupGrammarDownloadButton] {
            button.isHidden = !enabled || (state != .downloadRequired && state != .unavailable)
            button.title = state == .unavailable ? "Retry Download" : "Download Grammar Model"
        }
    }

    @objc private func prepareGrammarModel() {
        updateGrammarCorrection(enabled: true, state: .downloading(0))
        onPrepareGrammarModel?()
    }

    @objc private func changeGrammarCorrection(_ sender: NSButton) {
        let enabled = sender.state == .on
        updateGrammarCorrection(enabled: enabled, state: enabled ? .waiting : .off)
        onGrammarCorrectionChanged?(enabled)
    }

    func updateCaptureMode(_ mode: CaptureMode) {
        captureMode = mode
        toggleCheckbox.state = mode == .toggle ? .on : .off
        gestureHint.stringValue = mode == .toggle ? "press to start / finish" : "hold to speak"
        updateTrigger(dictationTrigger)
    }

    @objc private func changeCaptureMode() {
        updateCaptureMode(toggleCheckbox.state == .on ? .toggle : .hold)
        onCaptureModeChanged?(captureMode)
    }

    func updateLaunchAtLogin(enabled: Bool, message: String? = nil) {
        launchAtLoginCheckbox.state = enabled ? .on : .off
        launchAtLoginNote.stringValue = message ?? "Start VoxKey automatically when you log in."
        launchAtLoginNote.textColor = message == nil ? VoxKeyDesign.secondaryInk : VoxKeyDesign.warm
    }

    @objc private func changeLaunchAtLogin() {
        onLaunchAtLoginChanged?(launchAtLoginCheckbox.state == .on)
    }

    func updateTrigger(_ trigger: DictationTrigger) {
        dictationTrigger = trigger
        triggerPopup.selectItem(at: DictationTrigger.allCases.firstIndex(of: trigger) ?? 0)
        triggerHint.stringValue = trigger.hint
        triggerKeyLabel.stringValue = trigger.displayName
        readinessInstructions.stringValue = isComplete
            ? "That’s the whole flow. Finish setup, then use \(trigger.displayName) whenever you want to dictate."
            : "When the checks are ready, click below. Hold \(trigger.displayName), say a sentence, and release to see your words arrive."
        if !isComplete, captureMode == .toggle {
            readinessInstructions.stringValue = "When the checks are ready, click below. Press \(trigger.displayName), say a sentence, and press again to finish."
        }
        testTextView.setAccessibilityHelp(readinessInstructions.stringValue)
    }

    @objc private func changeTrigger() {
        let trigger = DictationTrigger.allCases[triggerPopup.indexOfSelectedItem]
        updateTrigger(trigger)
        onTriggerChanged?(trigger)
    }

    var isTestFieldFocused: Bool {
        guard window?.isKeyWindow == true else { return false }
        return window?.firstResponder === testTextView || window?.firstResponder === testTextView.inputContext?.client
    }

    func present() {
        showWindow(nil)
        window?.orderFrontRegardless()
        activationCoordinator.present { [weak window] in
            guard window?.isVisible == true else { return }
            window?.makeKeyAndOrderFront(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        activationCoordinator.restorePreviousApplication()
        onClose?()
    }

    func update(
        microphone: Bool,
        accessibility: Bool,
        modelPhase: ModelPreparationPhase,
        message: String?
    ) {
        setPermission(indicator: microphoneIndicator, state: microphoneState, number: "01", ready: microphone, active: true)
        setPermission(indicator: accessibilityIndicator, state: accessibilityState, number: "02", ready: accessibility, active: microphone)
        microphoneButton.isHidden = microphone
        accessibilityButton.isHidden = !microphone || accessibility
        let modelActive = microphone && accessibility
        setPermission(indicator: modelIndicator, state: modelState, number: "03", ready: false, active: modelActive)
        modelStatus.stringValue = "English model"
        modelStatus.textColor = VoxKeyDesign.ink
        switch modelPhase {
        case .required:
            modelButton.title = "Prepare English Model"
            modelButton.isHidden = !modelActive
            modelButton.isEnabled = true
            modelProgress.isHidden = true
            modelProgress.stopAnimation(nil)
        case let .downloading(fraction):
            let progress = min(max(fraction, 0), 1)
            modelState.stringValue = "\(Int((progress * 100).rounded()))%"
            modelIndicator.stringValue = "↓"
            modelIndicator.textColor = VoxKeyDesign.accentInk
            modelButton.isHidden = true
            modelProgress.isIndeterminate = false
            modelProgress.doubleValue = progress
            modelProgress.isHidden = false
        case .prewarming:
            modelState.stringValue = "Optimizing…"
            modelIndicator.stringValue = "↻"
            modelIndicator.textColor = VoxKeyDesign.accentInk
            modelButton.isHidden = true
            modelProgress.isIndeterminate = true
            modelProgress.isHidden = false
            modelProgress.startAnimation(nil)
        case .ready:
            setPermission(indicator: modelIndicator, state: modelState, number: "03", ready: true, active: true)
            modelButton.isHidden = true
            modelProgress.isHidden = true
            modelProgress.stopAnimation(nil)
        case .failed:
            modelState.stringValue = "Try again"
            modelState.textColor = VoxKeyDesign.warm
            modelIndicator.stringValue = "!"
            modelIndicator.textColor = VoxKeyDesign.warm
            modelButton.title = "Resume Preparation"
            modelButton.isHidden = !modelActive
            modelButton.isEnabled = true
            modelProgress.isHidden = true
            modelProgress.stopAnimation(nil)
        }
        // An action already communicates the pending state; avoid competing labels.
        microphoneState.isHidden = !microphoneButton.isHidden
        accessibilityState.isHidden = !accessibilityButton.isHidden
        modelState.isHidden = !modelButton.isHidden
        if !isComplete {
            messageLabel.stringValue = message ?? "Your audio and words stay on this Mac."
        }
    }

    func markComplete() {
        guard !isComplete else { return }
        isComplete = true
        testTextView.isEditable = false
        finishButton.isHidden = false
        readinessTitle.stringValue = "You’re all set."
        updateTrigger(dictationTrigger)
        readinessState.stringValue = "FIRST WORDS DELIVERED ✓"
        readinessState.textColor = VoxKeyDesign.accentInk
        readinessCard.borderColor = VoxKeyDesign.accentInk.withAlphaComponent(0.45)
        messageLabel.stringValue = "Your first dictation was delivered. VoxKey is ready in the menu bar."
        window?.makeFirstResponder(finishButton)
    }

    func resetCompletionState() {
        isComplete = false
        testTextView.isEditable = true
        finishButton.isHidden = true
        readinessTitle.stringValue = "Give it a first word."
        updateTrigger(dictationTrigger)
        readinessState.stringValue = "READINESS CHECK"
        readinessState.textColor = VoxKeyDesign.secondaryInk
        readinessCard.borderColor = VoxKeyDesign.border
    }

    private func permissionRow(status: NSTextField, indicator: NSTextField, state: NSTextField, button: NSButton) -> NSView {
        indicator.font = VoxKeyDesign.TextStyle.indicator.font
        indicator.alignment = .center
        indicator.textColor = VoxKeyDesign.secondaryInk
        indicator.widthAnchor.constraint(equalToConstant: 24).isActive = true
        indicator.setAccessibilityElement(false)
        status.font = VoxKeyDesign.TextStyle.emphasis.font
        status.textColor = VoxKeyDesign.ink
        state.font = VoxKeyDesign.TextStyle.footnoteEmphasis.font
        state.textColor = VoxKeyDesign.secondaryInk
        let row = horizontal([indicator, status, NSView(), state, button], spacing: 10)
        row.heightAnchor.constraint(equalToConstant: 46).isActive = true
        return row
    }

    private func setPermission(indicator: NSTextField, state: NSTextField, number: String, ready: Bool, active: Bool) {
        indicator.stringValue = ready ? "✓" : number
        indicator.textColor = ready ? VoxKeyDesign.accentInk : VoxKeyDesign.secondaryInk
        state.stringValue = ready ? "Ready" : (active ? "Required" : "Up next")
        state.textColor = ready ? VoxKeyDesign.accentInk : VoxKeyDesign.secondaryInk
    }

    private func horizontal(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func vertical(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func embed(_ content: NSView, in container: NSView, inset: NSEdgeInsets) {
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset.left),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset.right),
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: inset.top),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -inset.bottom)
        ])
        if let stack = content as? NSStackView {
            for view in stack.arrangedSubviews {
                view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
    }

    private func separator() -> NSView {
        let line = VoxKeyCardView(fill: VoxKeyDesign.border, border: .clear, cornerRadius: 0)
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    private func keycap(_ title: String) -> NSView {
        let key = VoxKeyCardView(fill: VoxKeyDesign.insetSurface, cornerRadius: 4)
        let label = VoxKeyDesign.label(title, style: .micro, color: VoxKeyDesign.secondaryInk)
        embed(label, in: key, inset: NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6))
        return key
    }

    @objc private func requestMicrophone() { onRequestMicrophone?() }
    @objc private func requestAccessibility() { onRequestAccessibility?() }
    @objc private func prepareModel() { onPrepareModel?() }
    @objc private func finishSetup() { onFinish?() }
}
