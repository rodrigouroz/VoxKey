import AppKit
import VoxKeyCore

/// A single window for everyday preferences and the speech-model library.
/// First-run setup and the readiness check live in OnboardingWindowController.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    enum Pane: String, CaseIterable {
        case general, dictation, models

        var title: String {
            switch self {
            case .general: "General"
            case .dictation: "Dictation"
            case .models: "Models & Languages"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .dictation: "mic"
            case .models: "waveform"
            }
        }

        var identifier: NSToolbarItem.Identifier { .init(rawValue) }
    }

    private(set) var selectedPane = Pane.general
    let models = ModelSettingsViewController()
    private var panes: [Pane: NSView] = [:]
    private let defaults: UserDefaults?
    private let grammarAvailable: Bool
    private static let panePreferenceKey = "VoxKeySettingsPane"
    var onTriggerChanged: ((DictationTrigger) -> Void)?
    var onCaptureModeChanged: ((CaptureMode) -> Void)?
    var onMicrophoneChanged: ((String?) -> Void)?
    var onLaunchAtLoginChanged: ((Bool) -> Void)?
    var onGrammarCorrectionChanged: ((Bool) -> Void)?
    var onPrepareGrammarModel: (() -> Void)?

    let triggerPopup = NSPopUpButton()
    let toggleCheckbox = NSButton(checkboxWithTitle: "Toggle Dictation", target: nil, action: nil)
    let microphonePopup = NSPopUpButton()
    let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch at Login", target: nil, action: nil)
    let grammar = GrammarCorrectionCard(title: "Improve transcription")
    var grammarCheckbox: NSButton { grammar.checkbox }
    private(set) var dictationTrigger: DictationTrigger = .globe

    private let triggerHint = VoxKeyDesign.label("", style: .caption, color: VoxKeyDesign.secondaryInk)
    private let microphoneNote = VoxKeyDesign.label("", style: .caption, color: VoxKeyDesign.secondaryInk)
    private let launchAtLoginNote = VoxKeyDesign.label(
        "Start VoxKey automatically when you log in.", style: .caption, color: VoxKeyDesign.secondaryInk)
    private var microphoneUIDs: [String?] = []
    private var pinnedMicrophoneMissing = false
    private let activationCoordinator: ApplicationActivationCoordinator

    init(
        activationCoordinator: ApplicationActivationCoordinator = ApplicationActivationCoordinator(),
        grammarAvailable: Bool = GrammarCorrector.isAvailable,
        defaults: UserDefaults? = nil
    ) {
        self.activationCoordinator = activationCoordinator
        self.grammarAvailable = grammarAvailable
        self.defaults = defaults
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 270),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.backgroundColor = VoxKeyDesign.canvas
        window.toolbarStyle = .preference
        super.init(window: window)
        window.delegate = self

        triggerPopup.addItems(withTitles: DictationTrigger.allCases.map(\.displayName))
        triggerPopup.setAccessibilityLabel("Dictation trigger")
        triggerPopup.target = self
        triggerPopup.action = #selector(changeTrigger)
        toggleCheckbox.target = self
        toggleCheckbox.action = #selector(changeCaptureMode)
        let dictation = VoxKeyDesign.section([
            VoxKeyDesign.label("Dictation", style: .sectionTitle),
            VoxKeyDesign.label("Trigger key", style: .emphasis),
            triggerPopup,
            triggerHint,
            VoxKeyDesign.separator(),
            toggleCheckbox,
            VoxKeyDesign.label(
                "Press once to start, again to finish. Off: hold the trigger while speaking.",
                style: .caption, color: VoxKeyDesign.secondaryInk)
        ])

        microphonePopup.setAccessibilityLabel("Microphone")
        microphonePopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        microphonePopup.cell?.lineBreakMode = .byTruncatingMiddle
        microphonePopup.target = self
        microphonePopup.action = #selector(changeMicrophone)
        let microphone = VoxKeyDesign.section([
            VoxKeyDesign.label("Microphone", style: .sectionTitle),
            microphonePopup,
            microphoneNote
        ])

        grammar.onToggle = { [weak self] enabled in self?.onGrammarCorrectionChanged?(enabled) }
        grammar.onDownload = { [weak self] in self?.onPrepareGrammarModel?() }
        grammar.isHidden = !grammarAvailable

        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(changeLaunchAtLogin)
        let general = VoxKeyDesign.section([
            VoxKeyDesign.label("General", style: .sectionTitle),
            launchAtLoginCheckbox,
            launchAtLoginNote
        ])

        let feedbackButton = NSButton(title: "Send Feedback…", target: self, action: #selector(openFeedback))
        VoxKeyDesign.configureButton(feedbackButton)
        feedbackButton.setAccessibilityHelp("Email hello@rodrigouroz.com to report a bug or suggest a feature.")
        let feedbackAddress = VoxKeyDesign.label("hello@rodrigouroz.com", style: .caption, color: VoxKeyDesign.secondaryInk)
        feedbackAddress.isSelectable = true
        let feedback = VoxKeyDesign.section([
            VoxKeyDesign.label("Feedback", style: .sectionTitle),
            VoxKeyDesign.horizontal([feedbackAddress, NSView(), feedbackButton])
        ])

        panes[.general] = VoxKeyDesign.contentView(VoxKeyDesign.vertical([general, feedback], spacing: VoxKeyDesign.Layout.sectionSpacing))
        var dictationSections: [NSView] = [dictation, microphone, grammar]
        #if DEBUG && VOXKEY_LOCAL_DIAGNOSTICS && !VOXKEY_RELEASE
        dictationSections.append(TranscriptionDiagnosticsCard())
        #endif
        panes[.dictation] = VoxKeyDesign.contentView(VoxKeyDesign.vertical(dictationSections, spacing: VoxKeyDesign.Layout.sectionSpacing))
        panes[.models] = models.view
        let toolbar = NSToolbar(identifier: "VoxKey.Settings")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.allowsDisplayModeCustomization = false
        toolbar.displayMode = .iconAndLabel
        window.toolbar = toolbar
        selectPane(Pane(rawValue: defaults?.string(forKey: Self.panePreferenceKey) ?? "") ?? .general)
        window.center()
        updateMicrophones(AudioInputCatalog(), pinnedUID: nil)
        updateTrigger(.globe)
        updateCaptureMode(.hold)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(pane: Pane? = nil) {
        if let pane { selectPane(pane) }
        showWindow(nil)
        window?.orderFrontRegardless()
        activationCoordinator.present { [weak window] in
            guard window?.isVisible == true else { return }
            window?.makeKeyAndOrderFront(nil)
        }
    }

    func selectPane(_ pane: Pane) {
        guard let window, let content = panes[pane] else { return }
        window.makeFirstResponder(nil)
        let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        selectedPane = pane
        window.contentView = content
        let size: NSSize = switch pane {
        case .general: NSSize(width: 580, height: 270)
        case .dictation: NSSize(width: 580, height: grammarAvailable ? 590 : 440)
        case .models: NSSize(width: 820, height: 750)
        }
        var contentSize = size
        #if DEBUG && VOXKEY_LOCAL_DIAGNOSTICS && !VOXKEY_RELEASE
        if pane == .dictation { contentSize.height += 180 }
        #endif
        window.setContentSize(contentSize)
        window.setFrameTopLeftPoint(topLeft)
        window.title = pane.title
        window.toolbar?.selectedItemIdentifier = pane.identifier
        defaults?.set(pane.rawValue, forKey: Self.panePreferenceKey)
        content.layoutSubtreeIfNeeded()
        window.recalculateKeyViewLoop()
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Pane.allCases.map(\.identifier)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let pane = Pane(rawValue: identifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = pane.title
        item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(changePane(_:))
        return item
    }

    @objc private func changePane(_ sender: NSToolbarItem) {
        guard let pane = Pane(rawValue: sender.itemIdentifier.rawValue) else { return }
        selectPane(pane)
    }

    func windowWillClose(_ notification: Notification) {
        activationCoordinator.restorePreviousApplication()
    }

    func updateTrigger(_ trigger: DictationTrigger) {
        dictationTrigger = trigger
        triggerPopup.selectItem(at: DictationTrigger.allCases.firstIndex(of: trigger) ?? 0)
        triggerHint.stringValue = trigger.hint
    }

    func updateCaptureMode(_ mode: CaptureMode) {
        toggleCheckbox.state = mode == .toggle ? .on : .off
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

    func updateLaunchAtLogin(enabled: Bool, message: String? = nil) {
        launchAtLoginCheckbox.state = enabled ? .on : .off
        launchAtLoginNote.stringValue = message ?? "Start VoxKey automatically when you log in."
        launchAtLoginNote.textColor = message == nil ? VoxKeyDesign.secondaryInk : VoxKeyDesign.warm
    }

    func updateGrammarCorrection(enabled: Bool, state: GrammarCorrectionState) {
        grammar.update(enabled: enabled, state: state)
    }

    @objc private func changeTrigger() {
        let trigger = DictationTrigger.allCases[triggerPopup.indexOfSelectedItem]
        updateTrigger(trigger)
        onTriggerChanged?(trigger)
    }

    @objc private func changeCaptureMode() {
        onCaptureModeChanged?(toggleCheckbox.state == .on ? .toggle : .hold)
    }

    @objc private func changeMicrophone() {
        guard microphoneUIDs.indices.contains(microphonePopup.indexOfSelectedItem) else { return }
        onMicrophoneChanged?(microphoneUIDs[microphonePopup.indexOfSelectedItem])
    }

    @objc private func changeLaunchAtLogin() {
        onLaunchAtLoginChanged?(launchAtLoginCheckbox.state == .on)
    }

    @objc private func openFeedback() {
        guard let url = URL(string: "mailto:hello@rodrigouroz.com?subject=VoxKey%20feedback") else { return }
        NSWorkspace.shared.open(url)
    }
}
