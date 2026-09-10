import AppKit
import VoxKeyCore

/// First-run setup: permissions, the transcription model, optional grammar
/// correction, and the readiness check. Everyday preferences live in
/// SettingsWindowController.
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    var onRequestMicrophone: (() -> Void)?
    var onRequestAccessibility: (() -> Void)?
    var onChooseModel: (() -> Void)?
    var onFinish: (() -> Void)?
    var onClose: (() -> Void)?
    var onGrammarCorrectionChanged: ((Bool) -> Void)?
    var onPrepareGrammarModel: (() -> Void)?

    let grammar = GrammarCorrectionCard(title: "Correct grammar locally (optional)")
    var setupGrammarCheckbox: NSButton { grammar.checkbox }
    let testTextView = NSTextView()
    private(set) var dictationTrigger: DictationTrigger = .globe
    private var captureMode: CaptureMode = .hold

    private let microphoneStatus = NSTextField(labelWithString: "Microphone")
    private let accessibilityStatus = NSTextField(labelWithString: "Accessibility")
    private let modelStatus = NSTextField(labelWithString: "Transcription model")
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
    private let modelButton = NSButton(title: "Choose Model…", target: nil, action: nil)
    private let finishButton = NSButton(title: "Finish Setup", target: nil, action: nil)
    private static let readinessPrompt = "When the checks are ready, click below. Hold Globe/Fn, say a sentence, and release to see your words arrive."
    private let readinessInstructions = VoxKeyDesign.label(OnboardingWindowController.readinessPrompt, style: .caption, color: VoxKeyDesign.secondaryInk)
    private let readinessTitle = VoxKeyDesign.label("Give it a first word.", style: .sectionTitle)
    private let readinessState = VoxKeyDesign.label("Readiness check", style: .footnoteEmphasis, color: VoxKeyDesign.secondaryInk)
    private let readinessCard = VoxKeyCardView()
    private let gestureHint = VoxKeyDesign.label("hold to speak", style: .footnote, color: VoxKeyDesign.secondaryInk)
    private let triggerKeyLabel = VoxKeyDesign.label("Globe/Fn", style: .micro, color: VoxKeyDesign.secondaryInk)
    private let activationCoordinator: ApplicationActivationCoordinator
    private var isComplete = false

    init(
        activationCoordinator: ApplicationActivationCoordinator = ApplicationActivationCoordinator(),
        grammarAvailable: Bool = GrammarCorrector.isAvailable
    ) {
        self.activationCoordinator = activationCoordinator
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 656, height: grammarAvailable ? 780 : 660),
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

        let title = VoxKeyDesign.label("Press. Speak.\nRelease.", style: .onboardingHero)
        let subtitle = VoxKeyDesign.label(
            "VoxKey transcribes entirely on this Mac and safely inserts the final text into the field you chose.",
            color: VoxKeyDesign.secondaryInk
        )
        let heroCopy = VoxKeyDesign.vertical([title, subtitle], spacing: 10)
        let mark = VoxKeyBrandMarkView(size: 118)
        let hero = VoxKeyDesign.horizontal([heroCopy, NSView(), mark], spacing: 28)
        heroCopy.widthAnchor.constraint(equalToConstant: 404).isActive = true

        modelProgress.style = .bar
        modelProgress.controlSize = .small
        modelProgress.minValue = 0
        modelProgress.maxValue = 1
        modelProgress.isHidden = true
        modelProgress.setAccessibilityLabel("Transcription model preparation progress")

        let permissionCard = VoxKeyCardView()
        let permissionRows = VoxKeyDesign.vertical([
            permissionRow(status: microphoneStatus, indicator: microphoneIndicator, state: microphoneState, button: microphoneButton),
            VoxKeyDesign.separator(),
            permissionRow(status: accessibilityStatus, indicator: accessibilityIndicator, state: accessibilityState, button: accessibilityButton),
            VoxKeyDesign.separator(),
            permissionRow(status: modelStatus, indicator: modelIndicator, state: modelState, button: modelButton)
        ], spacing: 0)
        embed(permissionRows, in: permissionCard, inset: NSEdgeInsets(top: 5, left: 16, bottom: 5, right: 16))
        let setupHeading = VoxKeyDesign.horizontal([
            VoxKeyDesign.label("A little setup", style: .sectionTitle),
            NSView(),
            VoxKeyDesign.label("Three checks. Then you’re in.", style: .footnote, color: VoxKeyDesign.secondaryInk)
        ], spacing: 8)
        let prerequisites = VoxKeyDesign.vertical([setupHeading, permissionCard, modelProgress], spacing: 10)

        let checkHeading = VoxKeyDesign.horizontal([readinessTitle, NSView(), readinessState])
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
        let field = VoxKeyDesign.textField(testTextView, minimumHeight: 86)
        field.heightAnchor.constraint(equalToConstant: 86).isActive = true
        let keyHint = VoxKeyDesign.horizontal([
            triggerKeyLabel,
            gestureHint,
            NSView(),
            VoxKeyDesign.label("Esc to cancel", style: .footnote, color: VoxKeyDesign.secondaryInk)
        ], spacing: 6)
        VoxKeyDesign.embed(VoxKeyDesign.vertical([checkHeading, readinessInstructions, field, keyHint]), in: readinessCard)

        messageLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let completionActions = VoxKeyDesign.horizontal([messageLabel, NSView(), finishButton], spacing: 16)
        completionActions.heightAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true

        grammar.onToggle = { [weak self] enabled in self?.onGrammarCorrectionChanged?(enabled) }
        grammar.onDownload = { [weak self] in self?.onPrepareGrammarModel?() }
        grammar.isHidden = !grammarAvailable

        let stack = VoxKeyDesign.vertical(
            [hero, prerequisites, grammar, readinessCard, completionActions],
            spacing: VoxKeyDesign.Layout.sectionSpacing
        )
        VoxKeyDesign.install(stack, in: window)
        updateTrigger(.globe)
        update(microphone: false, accessibility: false, modelPhase: .required, message: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateGrammarCorrection(enabled: Bool, state: GrammarCorrectionState) {
        grammar.update(enabled: enabled, state: state)
    }

    func updateCaptureMode(_ mode: CaptureMode) {
        captureMode = mode
        gestureHint.stringValue = mode == .toggle ? "press to start / finish" : "hold to speak"
        updateTrigger(dictationTrigger)
    }

    func updateTrigger(_ trigger: DictationTrigger) {
        dictationTrigger = trigger
        triggerKeyLabel.stringValue = trigger.displayName
        readinessInstructions.stringValue = isComplete
            ? "That’s the whole flow. Finish setup, then use \(trigger.displayName) whenever you want to dictate."
            : "When the checks are ready, click below. Hold \(trigger.displayName), say a sentence, and release to see your words arrive."
        if !isComplete, captureMode == .toggle {
            readinessInstructions.stringValue = "When the checks are ready, click below. Press \(trigger.displayName), say a sentence, and press again to finish."
        }
        testTextView.setAccessibilityHelp(readinessInstructions.stringValue)
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
        modelStatus.stringValue = "Transcription model"
        modelStatus.textColor = VoxKeyDesign.ink
        switch modelPhase {
        case .required:
            modelButton.title = "Choose Model…"
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
            modelButton.title = "Change Model…"
            modelButton.isHidden = false
            modelButton.isEnabled = true
            modelProgress.isHidden = true
            modelProgress.stopAnimation(nil)
        case .failed:
            modelState.stringValue = "Try again"
            modelState.textColor = VoxKeyDesign.warm
            modelIndicator.stringValue = "!"
            modelIndicator.textColor = VoxKeyDesign.warm
            modelButton.title = "Choose Model…"
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
        readinessState.stringValue = "First words delivered ✓"
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
        readinessState.stringValue = "Readiness check"
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
        let row = VoxKeyDesign.horizontal([indicator, status, NSView(), state, button], spacing: 10)
        row.heightAnchor.constraint(equalToConstant: 46).isActive = true
        return row
    }

    private func setPermission(indicator: NSTextField, state: NSTextField, number: String, ready: Bool, active: Bool) {
        indicator.stringValue = ready ? "✓" : number
        indicator.textColor = ready ? VoxKeyDesign.accentInk : VoxKeyDesign.secondaryInk
        state.stringValue = ready ? "Ready" : (active ? "Required" : "Up next")
        state.textColor = ready ? VoxKeyDesign.accentInk : VoxKeyDesign.secondaryInk
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
    }

    @objc private func requestMicrophone() { onRequestMicrophone?() }
    @objc private func requestAccessibility() { onRequestAccessibility?() }
    @objc private func prepareModel() { onChooseModel?() }
    @objc private func finishSetup() { onFinish?() }
}
