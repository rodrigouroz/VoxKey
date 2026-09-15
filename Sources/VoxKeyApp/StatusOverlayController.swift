import AppKit
import QuartzCore
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
    private let transcriptView = TranscriptPreviewView()
    private let header = NSView()
    private let headerHeight: NSLayoutConstraint
    private let animationsEnabled: Bool
    private struct Presentation: Equatable {
        let phase: DictationPhase
        let message: String?
        let attention: SessionAttention?
        let trigger: DictationTrigger
        let captureMode: CaptureMode
        let transcriptPreview: String?
        let provisionalPreview: String?
    }
    private var presentation: Presentation?

    init(animationsEnabled: Bool = true) {
        self.animationsEnabled = animationsEnabled
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
        header.translatesAutoresizingMaskIntoConstraints = false
        headerHeight = header.heightAnchor.constraint(equalToConstant: 46)
        surface.addSubview(header)
        header.addSubview(row)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: surface.topAnchor),
            header.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            headerHeight,
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            row.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -14),
            row.centerYAnchor.constraint(equalTo: header.centerYAnchor)
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
                                trigger: snapshot.trigger, captureMode: snapshot.captureMode,
                                transcriptPreview: snapshot.transcriptPreview, provisionalPreview: snapshot.provisionalPreview)
        // Meter ticks do not change layout, window order, or the lifetime of a toast.
        if presentation == next, window?.isVisible == true || !snapshot.phase.isBusy { return }
        presentation = next
        hideTask?.cancel()
        switch snapshot.phase {
        case .capturing, .finalizing, .delivering: break
        default:
            transcriptView.clear()
            transcriptView.removeFromSuperview()
        }
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
            show(symbol: snapshot.captureMode == .toggle ? "mic.badge.plus" : "mic.fill", title: title,
                 preview: snapshot.transcriptPreview, provisional: snapshot.provisionalPreview)
        case .finalizing:
            show(symbol: "waveform", title: snapshot.message ?? "Transcribing…", preview: snapshot.transcriptPreview,
                 provisional: snapshot.provisionalPreview)
        case .delivering:
            if let preview = snapshot.transcriptPreview {
                show(symbol: "text.cursor", title: "Inserting…", preview: preview)
            } else {
                window?.orderOut(nil)
            }
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

    private var shouldAnimate: Bool {
        animationsEnabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func show(symbol: String, title: String, needsAttention: Bool = false, preview: String? = nil, provisional: String? = nil) {
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        iconView.contentTintColor = needsAttention ? VoxKeyDesign.Overlay.attention : VoxKeyDesign.accent
        statusLabel.stringValue = title
        let wasVisible = window?.isVisible == true
        let hadPreview = transcriptView.superview != nil
        if !(preview ?? "").isEmpty || !(provisional ?? "").isEmpty, let surface = window?.contentView {
            if !hadPreview {
                surface.addSubview(transcriptView)
                transcriptView.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    transcriptView.topAnchor.constraint(equalTo: header.bottomAnchor),
                    transcriptView.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 18),
                    transcriptView.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -18),
                    transcriptView.bottomAnchor.constraint(equalTo: surface.bottomAnchor)
                ])
            }
            transcriptView.setText(preview ?? "", provisional: provisional)
        } else {
            transcriptView.clear()
            transcriptView.removeFromSuperview()
        }
        sizeToFitStatus(animated: wasVisible && shouldAnimate)
        transcriptView.revealLatest(animated: hadPreview && shouldAnimate)
        if !wasVisible { window?.orderFrontRegardless() }
    }

    private func sizeToFitStatus(animated: Bool) {
        // The recovery instruction must survive long messages. Normal capture stays compact.
        let textWidth = (statusLabel.stringValue as NSString).size(withAttributes: [
            .font: statusLabel.font ?? VoxKeyDesign.TextStyle.emphasis.font
        ]).width
        let chromeWidth: CGFloat = levelBar.isHidden ? 28 + 16 + 12 : 28 + 24 + 12 + 30 + 12
        let hasPreview = transcriptView.superview != nil
        let width = hasPreview ? 360 : min(360, max(212, ceil(textWidth) + chromeWidth))
        let availableTextWidth = width - chromeWidth
        statusLabel.preferredMaxLayoutWidth = availableTextWidth
        let titleHeight = statusLabel.cell?.cellSize(forBounds: NSRect(
            x: 0, y: 0, width: availableTextWidth, height: 1000
        )).height ?? 18
        let statusHeight = max(46, ceil(titleHeight) + 24)
        headerHeight.constant = statusHeight
        let previewHeight = hasPreview ? transcriptView.prepareLayout(width: width - 36) : 0
        let size = NSSize(width: width, height: statusHeight + (hasPreview ? previewHeight + 16 : 0))
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        let origin = screen.map { StatusOverlayPlacement.origin(windowSize: size, visibleFrame: $0.visibleFrame) }
            ?? window.frame.origin
        let frame = NSRect(origin: origin, size: size)
        if animated, window.frame != frame {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().setFrame(frame, display: true)
            }
        } else {
            window.setFrame(frame, display: true)
        }
        window.contentView?.layoutSubtreeIfNeeded()
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
