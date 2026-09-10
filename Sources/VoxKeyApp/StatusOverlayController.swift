import AppKit
import VoxKeyCore

@MainActor
final class StatusOverlayController: NSWindowController {
    private let levelBar = InputLevelBar()
    private let iconView = NSImageView()
    private let statusLabel = VoxKeyDesign.label("", style: .emphasis)
    private let triggerLabel = VoxKeyDesign.label("fn", style: .footnote, color: VoxKeyDesign.Overlay.secondaryInk)
    private let triggerKey = VoxKeyCardView(
        fill: VoxKeyDesign.Overlay.surface, border: VoxKeyDesign.Overlay.keyBorder, cornerRadius: 5
    )
    private var hideTask: Task<Void, Never>?
    private struct Presentation: Equatable {
        let phase: DictationPhase
        let message: String?
        let attention: SessionAttention?
        let trigger: DictationTrigger
        let captureMode: CaptureMode
    }
    private var presentation: Presentation?

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 212, height: 46),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none

        let surface = VoxKeyCardView(
            fill: VoxKeyDesign.Overlay.surface, border: VoxKeyDesign.Overlay.border, cornerRadius: 23
        )
        iconView.symbolConfiguration = .init(pointSize: 14, weight: .medium)
        iconView.contentTintColor = VoxKeyDesign.accent
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setAccessibilityElement(false)
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.textColor = VoxKeyDesign.Overlay.ink
        triggerLabel.alignment = .center
        triggerLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        triggerLabel.translatesAutoresizingMaskIntoConstraints = false
        triggerKey.addSubview(triggerLabel)
        NSLayoutConstraint.activate([
            triggerKey.widthAnchor.constraint(equalToConstant: 30),
            triggerKey.heightAnchor.constraint(equalToConstant: 23),
            triggerLabel.centerXAnchor.constraint(equalTo: triggerKey.centerXAnchor),
            triggerLabel.centerYAnchor.constraint(equalTo: triggerKey.centerYAnchor)
        ])
        let row = NSStackView(views: [iconView, levelBar, statusLabel, triggerKey])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(row)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            row.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -14),
            row.centerYAnchor.constraint(equalTo: surface.centerYAnchor)
        ])
        panel.contentView = surface
        super.init(window: panel)
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    isolated deinit { NotificationCenter.default.removeObserver(self) }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(_ snapshot: SessionSnapshot) {
        if case .capturing = snapshot.phase { levelBar.level = snapshot.inputLevel ?? 0 }
        let next = Presentation(phase: snapshot.phase, message: snapshot.message, attention: snapshot.attention,
                                trigger: snapshot.trigger, captureMode: snapshot.captureMode)
        // Meter ticks do not change layout, window order, or the lifetime of a toast.
        if presentation == next, window?.isVisible == true || !snapshot.phase.isBusy { return }
        presentation = next
        hideTask?.cancel()
        if case .capturing = snapshot.phase {
            levelBar.isHidden = false
            iconView.isHidden = true
            triggerKey.isHidden = false
            triggerLabel.stringValue = switch snapshot.trigger {
            case .globe: "fn"
            case .rightOption: "⌥"
            case .rightCommand: "⌘"
            case .rightControl: "⌃"
            }
            triggerLabel.setAccessibilityLabel(snapshot.trigger.displayName)
        } else {
            levelBar.isHidden = true
            iconView.isHidden = false
            triggerKey.isHidden = true
        }
        switch snapshot.phase {
        case .arming:
            show(symbol: "waveform", title: snapshot.message ?? "Starting…")
        case .capturing:
            let listening = snapshot.captureMode == .toggle
                ? "Listening — press \(snapshot.trigger.displayName) to finish" : "Listening"
            let detail = snapshot.message.flatMap { $0 == "Listening" ? nil : $0 }
            let title = detail.map { "\(listening)\n\($0)" } ?? listening
            show(symbol: snapshot.captureMode == .toggle ? "mic.badge.plus" : "mic.fill", title: title)
        case .finalizing:
            show(symbol: "waveform", title: snapshot.message == "Correcting grammar…" ? "Correcting grammar…" : "Transcribing…")
        case .delivering:
            window?.orderOut(nil)
        case .notReady:
            window?.orderOut(nil)
        case .ready:
            guard snapshot.attention != nil, snapshot.attention != .dictationReady,
                  let message = snapshot.message else {
                window?.orderOut(nil)
                return
            }
            show(
                symbol: snapshot.attention == .noSpeech ? "mic.slash" : "exclamationmark",
                title: message,
                needsAttention: snapshot.attention != .noSpeech
            )
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.8))
                guard !Task.isCancelled else { return }
                self?.window?.orderOut(nil)
            }
        }
    }

    private func show(symbol: String, title: String, needsAttention: Bool = false) {
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        iconView.contentTintColor = needsAttention ? VoxKeyDesign.Overlay.attention : VoxKeyDesign.accent
        statusLabel.stringValue = title
        sizeToFitStatus()
        positionOnActiveScreen()
        window?.orderFrontRegardless()
    }

    private func sizeToFitStatus() {
        // The recovery instruction must survive long messages. Normal capture stays compact.
        let textWidth = (statusLabel.stringValue as NSString).size(withAttributes: [
            .font: statusLabel.font ?? VoxKeyDesign.TextStyle.emphasis.font
        ]).width
        let chromeWidth: CGFloat = levelBar.isHidden ? 28 + 16 + 12 : 28 + 24 + 12 + 30 + 12
        let width = min(360, max(212, ceil(textWidth) + chromeWidth))
        let availableTextWidth = width - chromeWidth
        statusLabel.preferredMaxLayoutWidth = availableTextWidth
        let titleHeight = statusLabel.cell?.cellSize(forBounds: NSRect(
            x: 0, y: 0, width: availableTextWidth, height: 1000
        )).height ?? 18
        window?.setContentSize(NSSize(width: width, height: max(46, ceil(titleHeight) + 24)))
    }

    private func positionOnActiveScreen() {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }
        window.setFrameOrigin(StatusOverlayPlacement.origin(
            windowSize: window.frame.size,
            visibleFrame: visibleFrame
        ))
    }

    @objc private func screenParametersChanged() {
        guard window?.isVisible == true else { return }
        positionOnActiveScreen()
    }
}

enum StatusOverlayPlacement {
    static let edgeInset: CGFloat = 18

    static func origin(windowSize: NSSize, visibleFrame: NSRect) -> NSPoint {
        NSPoint(
            x: visibleFrame.maxX - windowSize.width - edgeInset,
            y: visibleFrame.maxY - windowSize.height - edgeInset
        )
    }
}

@MainActor
final class InputLevelBar: NSView {
    var level: Float = 0 { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: 24, height: 20) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 24).isActive = true
        heightAnchor.constraint(equalToConstant: 20).isActive = true
        setAccessibilityElement(false)
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let active = InputLevelMeter.segments(for: level)
        let heights: [CGFloat] = [9, 14, 19, 12, 14, 9]
        for index in 0..<6 {
            (index < active ? VoxKeyDesign.accent : VoxKeyDesign.Overlay.keyBorder).setFill()
            let height = heights[index]
            NSBezierPath(roundedRect: NSRect(x: CGFloat(index * 4), y: (20 - height) / 2,
                                            width: 2, height: height), xRadius: 1, yRadius: 1).fill()
        }
    }
}
