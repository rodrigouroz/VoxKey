import AppKit
import VoxKeyCore

/// Optional local grammar correction, rendered identically in setup and Settings.
/// Each window owns one card; AppController pushes the same state to both.
@MainActor
final class GrammarCorrectionCard: VoxKeyCardView {
    var onToggle: ((Bool) -> Void)?
    var onDownload: (() -> Void)?
    let checkbox: NSButton
    private let status = VoxKeyDesign.label("Off. No extra processing.", style: .caption, color: VoxKeyDesign.secondaryInk)
    private let download = NSButton(title: "Download Grammar Model", target: nil, action: nil)
    private var languageSupported = true
    private var lastEnabled = false
    private var lastState: GrammarCorrectionState = .off

    init(title: String) {
        checkbox = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        super.init(fill: VoxKeyDesign.surface, border: VoxKeyDesign.border, cornerRadius: VoxKeyDesign.Layout.cardRadius)
        checkbox.target = self
        checkbox.action = #selector(toggle)
        download.target = self
        download.action = #selector(requestDownload)
        download.isHidden = true
        VoxKeyDesign.configureButton(download)
        let explanation = VoxKeyDesign.label(
            "Fix basic English grammar locally. Correction starts while you dictate. Adds processing and may change words.",
            style: .caption, color: VoxKeyDesign.secondaryInk)
        let terms = VoxKeyDesign.label(
            "519 MB download when enabled · Model for noncommercial use only",
            style: .caption, color: VoxKeyDesign.secondaryInk)
        let statusRow = VoxKeyDesign.horizontal([status, NSView(), download], spacing: 8)
        let content = VoxKeyDesign.vertical([checkbox, explanation, statusRow, terms], spacing: 6)
        VoxKeyDesign.embed(content, in: self)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(enabled: Bool, state: GrammarCorrectionState) {
        lastEnabled = enabled
        lastState = state
        checkbox.isEnabled = languageSupported
        checkbox.state = enabled ? .on : .off
        status.stringValue = languageSupported ? state.message : "Paused. Grammar correction requires English as the dictation language."
        download.isHidden = !languageSupported || !enabled || (state != .downloadRequired && state != .unavailable)
        download.title = state == .unavailable ? "Retry Download" : "Download Grammar Model"
    }

    func updateLanguage(supported: Bool) {
        languageSupported = supported
        update(enabled: lastEnabled, state: lastState)
    }

    @objc private func toggle() {
        let enabled = checkbox.state == .on
        update(enabled: enabled, state: enabled ? .waiting : .off)
        onToggle?(enabled)
    }

    @objc private func requestDownload() {
        update(enabled: true, state: .downloading(0))
        onDownload?()
    }
}
