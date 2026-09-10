import AppKit
import VoxKeyCore

/// The same model library is reachable from first-run setup, Settings, and the menu bar.
@MainActor
final class ModelSettingsWindowController: NSWindowController, NSWindowDelegate {
    var onActivate: ((TranscriptionConfiguration) -> Void)?
    var onDownload: ((TranscriptionModel) -> Void)?
    let cards = TranscriptionModel.allCases.map { TranscriptionModelCard(model: $0) }
    let languagePopup = NSPopUpButton()
    let grammarNote = VoxKeyDesign.label("", style: .caption, color: VoxKeyDesign.secondaryInk)
    let activeLabel = VoxKeyDesign.label("", style: .caption, color: VoxKeyDesign.secondaryInk)
    let statusLabel = VoxKeyDesign.label("", style: .caption, color: VoxKeyDesign.secondaryInk)
    private let languagePanel: VoxKeyCardView
    private let activationCoordinator: ApplicationActivationCoordinator
    private var active = TranscriptionConfiguration()
    private var ready = false

    init(activationCoordinator: ApplicationActivationCoordinator = ApplicationActivationCoordinator()) {
        self.activationCoordinator = activationCoordinator
        languagePanel = VoxKeyDesign.section([
            VoxKeyDesign.horizontal([VoxKeyDesign.label("Dictation language", style: .emphasis), languagePopup]),
            grammarNote
        ])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 750),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Models and Languages"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        languagePopup.setAccessibilityLabel("Dictation language")
        languagePopup.target = self
        languagePopup.action = #selector(changeLanguage)
        for card in cards {
            card.onActivate = { [weak self] model in
                guard let self else { return }
                onActivate?(TranscriptionConfiguration(model: model, language: active.language))
            }
            card.onDownload = { [weak self] model in self?.onDownload?(model) }
        }
        let rows = stride(from: 0, to: cards.count, by: 2).map { index in
            let row = VoxKeyDesign.horizontal([cards[index], cards[index + 1]], spacing: 14)
            row.distribution = .fillEqually
            return row
        }
        let grid = VoxKeyDesign.vertical(rows, spacing: 14)
        let content = VoxKeyDesign.vertical([
            VoxKeyDesign.label("Find your speech model.", style: .windowTitle),
            VoxKeyDesign.label("Download any models you want to keep. Activate one for dictation.\nRecognition varies with your voice; compare a few familiar phrases.", color: VoxKeyDesign.secondaryInk),
            activeLabel, grid, languagePanel, statusLabel
        ], spacing: 16)
        VoxKeyDesign.install(content, in: window)
        update(active: active, ready: false, installed: [], busy: false)
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        showWindow(nil)
        activationCoordinator.present { [weak window] in window?.makeKeyAndOrderFront(nil) }
    }

    func windowWillClose(_ notification: Notification) {
        activationCoordinator.restorePreviousApplication()
    }

    func update(active: TranscriptionConfiguration, ready: Bool, installed: Set<TranscriptionModel>, busy: Bool,
                downloading: TranscriptionModel? = nil, downloadProgress: Double = 0,
                preparing: TranscriptionModel? = nil, message: String? = nil) {
        self.active = active
        self.ready = ready
        activeLabel.stringValue = ready
            ? "Active: \(active.model.name) · \(TranscriptionModel.languageName(active.language))"
            : "Download a model, then choose Use Model to start."
        for card in cards {
            card.update(installed: installed.contains(card.model), active: ready && active.model == card.model,
                        busy: busy, downloading: downloading, progress: downloadProgress, preparing: preparing)
        }
        let languages = active.model.languages
        let names = languages.map(TranscriptionModel.languageName)
        if languagePopup.itemTitles != names {
            languagePopup.removeAllItems()
            languagePopup.addItems(withTitles: names)
        }
        languagePopup.selectItem(at: languages.firstIndex(of: active.language) ?? 0)
        languagePopup.isEnabled = ready && active.model.multilingual && !busy
        languagePanel.isHidden = !ready
        grammarNote.stringValue = active.supportsGrammarCorrection
            ? "Optional English grammar correction is managed in Settings."
            : "Grammar correction is paused for this language setting. Dictation stays in the spoken language."
        statusLabel.stringValue = message ?? (busy
            ? "Finish the current dictation or model preparation before switching."
            : "Downloaded models stay on this Mac. Switching keeps your previous model active if preparation fails.")
    }

    @objc private func changeLanguage() {
        let languages = active.model.languages
        guard ready, languages.indices.contains(languagePopup.indexOfSelectedItem) else { return }
        onActivate?(TranscriptionConfiguration(model: active.model, language: languages[languagePopup.indexOfSelectedItem]))
    }
}

@MainActor
final class TranscriptionModelCard: VoxKeyCardView {
    let model: TranscriptionModel
    var onActivate: ((TranscriptionModel) -> Void)?
    var onDownload: ((TranscriptionModel) -> Void)?
    let actionButton = NSButton(title: "Download", target: nil, action: nil)
    let stateLabel = VoxKeyDesign.label("", style: .footnoteEmphasis, color: VoxKeyDesign.secondaryInk)
    let languageLabel: NSTextField
    private let progress = NSProgressIndicator()
    private var installed = false

    init(model: TranscriptionModel) {
        self.model = model
        languageLabel = VoxKeyDesign.label(model.multilingual ? "English, Spanish, and other Whisper languages" : "English only",
                                           style: .caption, color: VoxKeyDesign.secondaryInk)
        super.init(fill: VoxKeyDesign.surface, border: VoxKeyDesign.border, cornerRadius: VoxKeyDesign.Layout.cardRadius)
        actionButton.target = self
        actionButton.action = #selector(performAction)
        VoxKeyDesign.configureButton(actionButton, primary: true)
        progress.style = .bar
        progress.minValue = 0
        progress.maxValue = 1
        progress.setAccessibilityLabel("\(model.name) download progress")
        let title = VoxKeyDesign.label(model.multilingual ? "Whisper v3 Turbo" : "Distil-Whisper v3", style: .itemTitle)
        let variant = model == .distilCompressed || model == .turboCompressed ? "Compact" : "Full precision"
        let header = VoxKeyDesign.horizontal([title, NSView(), stateLabel], spacing: 8)
        let footer = VoxKeyDesign.horizontal([progress, NSView(), actionButton])
        footer.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let content = VoxKeyDesign.vertical([
            header,
            VoxKeyDesign.label("\(variant) · \(model.size) download", style: .emphasis),
            languageLabel,
            VoxKeyDesign.label(model.details, style: .caption, color: VoxKeyDesign.secondaryInk),
            footer
        ], spacing: 10)
        VoxKeyDesign.embed(content, in: self)
        heightAnchor.constraint(equalToConstant: 204).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    func update(installed: Bool, active: Bool, busy: Bool, downloading: TranscriptionModel?, progress value: Double,
                preparing: TranscriptionModel?) {
        self.installed = installed
        let loading = preparing == model
        let fetching = downloading == model
        stateLabel.stringValue = loading ? "Preparing…" : (fetching ? "Downloading…" : (active ? "Active ✓" : (installed ? "Downloaded" : "Not downloaded")))
        stateLabel.textColor = active ? VoxKeyDesign.accentInk : VoxKeyDesign.secondaryInk
        borderColor = active ? VoxKeyDesign.accentInk : VoxKeyDesign.border
        fillColor = active ? VoxKeyDesign.accentWash : VoxKeyDesign.surface
        actionButton.title = installed ? "Use Model" : "Download"
        actionButton.setAccessibilityLabel("\(actionButton.title): \(model.name)")
        actionButton.isHidden = active || fetching || loading
        actionButton.isEnabled = installed ? !busy : (downloading == nil && preparing == nil)
        progress.stopAnimation(nil)
        progress.isHidden = !fetching && !loading
        progress.isIndeterminate = loading
        progress.doubleValue = min(max(value, 0), 1)
        if loading { progress.startAnimation(nil) }
    }

    @objc private func performAction() {
        if installed { onActivate?(model) }
        else { onDownload?(model) }
    }
}
