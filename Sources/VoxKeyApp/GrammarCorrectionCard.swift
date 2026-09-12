import AppKit
import VoxKeyCore

/// Optional local transcript improvement, rendered identically in setup and Settings.
/// Each window owns one card; AppController pushes the same state to both.
@MainActor
final class GrammarCorrectionCard: VoxKeyCardView {
    var onToggle: ((Bool) -> Void)?
    var onDownload: (() -> Void)?
    let checkbox: NSButton
    private let status = VoxKeyDesign.label("Off. No extra processing.", style: .caption, color: VoxKeyDesign.secondaryInk)
    private let download = NSButton(title: "Download Improvement Models", target: nil, action: nil)
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
            "Remove fillers and repetitions, and improve English grammar on this Mac. Runs after you finish speaking and may change words.",
            style: .caption, color: VoxKeyDesign.secondaryInk)
        let terms = VoxKeyDesign.label(
            "Up to 2.03 GB download · S1-mini by Superwhisper · Grammar model for noncommercial use only",
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
        status.stringValue = languageSupported ? state.message : "Paused. Improve transcription requires English as the dictation language."
        download.isHidden = !languageSupported || !enabled || (state != .downloadRequired && state != .unavailable)
        download.title = state == .unavailable ? "Retry Setup" : "Download Improvement Models"
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
