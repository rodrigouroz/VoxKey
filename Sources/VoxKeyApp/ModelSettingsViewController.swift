import AppKit
import VoxKeyCore

/// One retained Settings pane, shared by setup and menu-bar navigation.
@MainActor
final class ModelSettingsViewController: NSViewController {
    var onActivate: ((TranscriptionConfiguration) -> Void)?
    var onDownload: ((TranscriptionModel) -> Void)?
    let cards = TranscriptionModel.allCases.map { TranscriptionModelCard(model: $0) }
    let languagePopup = NSPopUpButton()
    let grammarNote = VoxKeyDesign.label("", style: .caption, color: VoxKeyDesign.secondaryInk)
    let activeLabel = VoxKeyDesign.label("", style: .caption, color: VoxKeyDesign.secondaryInk)
    let statusLabel = VoxKeyDesign.label("", style: .caption, color: VoxKeyDesign.secondaryInk)
    private let languagePanel: VoxKeyCardView
    private var active = TranscriptionConfiguration()
    private var ready = false
    private var selectedLanguage = "en"
    private var availableLanguages = TranscriptionModel.turboFull.languages

    init() {
        languagePanel = VoxKeyDesign.section([
            VoxKeyDesign.horizontal([VoxKeyDesign.label("Dictation language", style: .emphasis), languagePopup]),
            grammarNote
        ])
        super.init(nibName: nil, bundle: nil)
        languagePopup.setAccessibilityLabel("Dictation language")
        languagePopup.target = self
        languagePopup.action = #selector(changeLanguage)
        for card in cards {
            card.onActivate = { [weak self] model in
                guard let self else { return }
                guard model.languages.contains(selectedLanguage) else { return }
                onActivate?(TranscriptionConfiguration(model: model, language: selectedLanguage))
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
        view = VoxKeyDesign.contentView(content)
        update(active: active, ready: false, installed: [], busy: false)
    }

    required init?(coder: NSCoder) { nil }

    func update(active: TranscriptionConfiguration, ready: Bool, installed: Set<TranscriptionModel>, busy: Bool,
                downloading: TranscriptionModel? = nil, downloadProgress: Double = 0,
                downloadElapsed: TimeInterval = 0,
                preparing: TranscriptionModel? = nil, message: String? = nil) {
        self.active = active
        self.ready = ready
        if ready { selectedLanguage = active.language }
        activeLabel.stringValue = ready
            ? "Active: \(active.model.name) · \(TranscriptionModel.languageName(active.language))"
            : "Download a model, then choose Use Model to start."
        for card in cards {
            card.update(installed: installed.contains(card.model), active: ready && active.model == card.model,
                        busy: busy, downloading: downloading, progress: downloadProgress, preparing: preparing,
                        downloadElapsed: downloadElapsed)
            if installed.contains(card.model), !card.model.languages.contains(selectedLanguage) {
                card.actionButton.isEnabled = false
            }
        }
        let languages = ready ? active.model.languages : TranscriptionModel.turboFull.languages
        availableLanguages = languages
        let names = languages.map(TranscriptionModel.languageName)
        if languagePopup.itemTitles != names {
            languagePopup.removeAllItems()
            languagePopup.addItems(withTitles: names)
        }
        languagePopup.selectItem(at: languages.firstIndex(of: selectedLanguage) ?? 0)
        languagePopup.isEnabled = (!ready || active.model.multilingual) && !busy
        languagePanel.isHidden = false
        grammarNote.stringValue = !ready
            ? "Choose your spoken language before Use Model. Spanish and automatic detection require Whisper v3 Turbo."
            : active.supportsGrammarCorrection
            ? "Optional English grammar correction is in the Dictation pane."
            : "Grammar correction is paused for this language setting. Dictation stays in the spoken language."
        statusLabel.stringValue = message ?? (downloading != nil
            ? ModelDownloadStatus(fraction: downloadProgress, elapsed: downloadElapsed).detail
            : busy
            ? "Finish the current dictation or model preparation before switching."
            : "Downloaded models stay on this Mac. Switching keeps your previous model active if preparation fails.")
    }

    @objc private func changeLanguage() {
        guard languagePopup.isEnabled, availableLanguages.indices.contains(languagePopup.indexOfSelectedItem) else { return }
        selectedLanguage = availableLanguages[languagePopup.indexOfSelectedItem]
        if ready {
            onActivate?(TranscriptionConfiguration(model: active.model, language: selectedLanguage))
        } else {
            for card in cards where card.actionButton.title == "Use Model" {
                card.actionButton.isEnabled = card.model.languages.contains(selectedLanguage)
            }
        }
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
    let progress = NSProgressIndicator()
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
        progress.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
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
                preparing: TranscriptionModel?, downloadElapsed: TimeInterval = 0) {
        self.installed = installed
        let loading = preparing == model
        let fetching = downloading == model
        let download = ModelDownloadStatus(fraction: value, elapsed: downloadElapsed)
        stateLabel.stringValue = loading ? "Preparing…" : (fetching ? download.title : (active ? "Active ✓" : (installed ? "Downloaded" : "Not downloaded")))
        stateLabel.textColor = active ? VoxKeyDesign.accentInk : VoxKeyDesign.secondaryInk
        borderColor = active ? VoxKeyDesign.accentInk : VoxKeyDesign.border
        fillColor = active ? VoxKeyDesign.accentWash : VoxKeyDesign.surface
        actionButton.title = installed ? "Use Model" : "Download"
        actionButton.setAccessibilityLabel("\(actionButton.title): \(model.name)")
        actionButton.isHidden = active || fetching || loading
        actionButton.isEnabled = installed ? !busy : (downloading == nil && preparing == nil)
        progress.stopAnimation(nil)
        progress.isHidden = !fetching && !loading
        progress.isIndeterminate = loading || (fetching && download.isIndeterminate)
        progress.doubleValue = download.fraction
        progress.setAccessibilityValue(fetching ? download.message : "Preparing model")
        if progress.isIndeterminate { progress.startAnimation(nil) }
    }

    @objc private func performAction() {
        if installed { onActivate?(model) }
        else { onDownload?(model) }
    }
}
