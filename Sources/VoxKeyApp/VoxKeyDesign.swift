import AppKit

/// Shared visual language for VoxKey's deliberately small native surfaces.
///
/// Neutrals come from the system so windows read as macOS windows in every
/// appearance and contrast setting. VoxKey owns only its brand colors: forest
/// green for actions, lime for the mark and highlights, amber for attention.
@MainActor
enum VoxKeyDesign {
    enum Layout {
        static let windowInset: CGFloat = 28
        static let windowVerticalInset: CGFloat = 20
        static let sectionSpacing: CGFloat = 20
        static let cardInset: CGFloat = 18
        static let contentSpacing: CGFloat = 12
        static let cardRadius: CGFloat = 12
        static let fieldRadius: CGFloat = 8
        static let fieldInset: CGFloat = 12
    }

    /// Every label in the app picks one of these. Ad-hoc sizes belong here, not at call sites.
    /// Titles and controls share the native system sans-serif family.
    enum TextStyle {
        case windowTitle, sectionTitle, itemTitle, body, emphasis, caption
        case footnote, footnoteEmphasis, micro, indicator, onboardingHero

        var font: NSFont {
            switch self {
            case .windowTitle: .systemFont(ofSize: 26, weight: .bold)
            case .sectionTitle: .systemFont(ofSize: 17, weight: .semibold)
            case .itemTitle: .systemFont(ofSize: 14, weight: .semibold)
            case .body: .systemFont(ofSize: 13)
            case .emphasis: .systemFont(ofSize: 13, weight: .medium)
            case .caption: .systemFont(ofSize: 12)
            case .footnote: .systemFont(ofSize: 11)
            case .footnoteEmphasis: .systemFont(ofSize: 11, weight: .medium)
            case .micro: .systemFont(ofSize: 10, weight: .medium)
            case .indicator: .monospacedSystemFont(ofSize: 11, weight: .semibold)
            case .onboardingHero: .systemFont(ofSize: 33, weight: .bold)
            }
        }
    }

    // MARK: System neutrals

    static let canvas = NSColor.windowBackgroundColor
    /// Grouped-form cards: white on the light window, a faint lift on the dark one.
    static let surface = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor.white.withAlphaComponent(0.065) : NSColor.white
    }
    static let insetSurface = NSColor.textBackgroundColor
    static let ink = NSColor.labelColor
    static let secondaryInk = NSColor.secondaryLabelColor
    static let border = NSColor.separatorColor

    // MARK: Brand colors

    /// Forest green: the color users read as VoxKey's accent. Fills primary buttons.
    static let brandGreen = adaptive(light: 0x356040, dark: 0x416B4D)
    /// Lime highlight. Deeper in light appearance so it still reads as a fill on a light window.
    static let accent = adaptive(light: 0xA9DC78, dark: 0xC1EF92)
    static let accentInk = adaptive(light: 0x356040, dark: 0xC1EF92)
    static let accentWash = adaptive(light: 0xEAF4E1, dark: 0x2B3B2B)
    static let warm = adaptive(light: 0xA35830, dark: 0xF2B68F)
    static let warmWash = adaptive(light: 0xFBEEE4, dark: 0x3B2F28)
    /// Waveform bars on the lime mark, in either appearance.
    static let accentForeground = fixed(0x1F3321)

    /// The recording pill keeps one dark forest surface in either system appearance.
    /// The public site's capture pill uses these same values.
    enum Overlay {
        static let surface = fixed(0x20382B)
        static let border = fixed(0x43523F)
        static let keyBorder = fixed(0x677C5D)
        static let ink = fixed(0xF0F5E8)
        static let secondaryInk = fixed(0xC1CEB7)
        static let attention = fixed(0xF2B68F)
    }

    // MARK: Components

    static func label(_ text: String, style: TextStyle = .body, color: NSColor = ink) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = style.font
        label.textColor = color
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }

    static func horizontal(_ views: [NSView], spacing: CGFloat = Layout.contentSpacing) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    static func vertical(_ views: [NSView], spacing: CGFloat = Layout.contentSpacing) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    static func embed(_ content: NSView, in container: NSView, inset: CGFloat = Layout.cardInset) {
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: inset),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -inset)
        ])
    }

    static func section(_ views: [NSView]) -> VoxKeyCardView {
        let card = VoxKeyCardView()
        embed(vertical(views), in: card)
        return card
    }

    /// A one-point rule in the system separator color.
    static func separator() -> NSView {
        let line = VoxKeyCardView(fill: border, border: .clear, cornerRadius: 0)
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    /// Native scrolling, selection, and editing inside the shared inset field.
    static func textField(_ textView: NSTextView, minimumHeight: CGFloat) -> VoxKeyCardView {
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = ink
        textView.backgroundColor = insetSurface
        textView.insertionPointColor = accentInk
        textView.textContainerInset = NSSize(width: Layout.fieldInset, height: Layout.fieldInset)
        textView.isRichText = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.backgroundColor = insetSurface
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = textView
        let field = VoxKeyCardView(fill: insetSurface, cornerRadius: Layout.fieldRadius)
        embed(scroll, in: field, inset: 1)
        field.heightAnchor.constraint(greaterThanOrEqualToConstant: minimumHeight).isActive = true
        return field
    }

    static func install(_ content: NSView, in window: NSWindow, fillsHeight: Bool = false) {
        window.titlebarAppearsTransparent = true
        window.backgroundColor = canvas
        let root = VoxKeyCardView(fill: canvas, border: .clear, cornerRadius: 0)
        window.contentView = root
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Layout.windowInset),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Layout.windowInset),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: Layout.windowVerticalInset),
            fillsHeight
                ? content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Layout.windowVerticalInset)
                : content.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -Layout.windowVerticalInset)
        ])
    }

    static func configureButton(_ button: NSButton, primary: Bool = false) {
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        // AppKit uses a white title on tinted rounded buttons. A deep green fill
        // preserves contrast while native rendering owns inactive/disabled states.
        button.bezelColor = primary ? brandGreen : nil
        button.contentTintColor = primary ? nil : ink
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    /// The menu bar mark: a keycap holding the waveform, as a template image so
    /// the system tints it for light, dark, and highlighted menu states.
    static func menuBarMark() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.setStroke()
            let key = NSBezierPath(roundedRect: rect.insetBy(dx: 1.25, dy: 1.75), xRadius: 4, yRadius: 4)
            key.lineWidth = 1.5
            key.stroke()
            NSColor.black.setFill()
            let heights: [CGFloat] = [3.5, 6.5, 9, 5.5, 3]
            let barWidth: CGFloat = 1.5
            let stride: CGFloat = 2.5
            for (index, height) in heights.enumerated() {
                let bar = NSRect(
                    x: rect.midX + CGFloat(index - 2) * stride - barWidth / 2,
                    y: rect.midY - height / 2,
                    width: barWidth,
                    height: height
                )
                NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "VoxKey"
        return image
    }

    private static func adaptive(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in fixed(appearance.isDark ? dark : light) }
    }

    nonisolated private static func fixed(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

private extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

@MainActor
class VoxKeyCardView: NSView {
    var fillColor: NSColor { didSet { needsDisplay = true } }
    var borderColor: NSColor { didSet { needsDisplay = true } }
    private let cornerRadius: CGFloat

    init(
        fill: NSColor = VoxKeyDesign.surface,
        border: NSColor = VoxKeyDesign.border,
        cornerRadius: CGFloat = VoxKeyDesign.Layout.cardRadius
    ) {
        self.fillColor = fill
        self.borderColor = border
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fillColor.cgColor
            layer?.borderColor = borderColor.cgColor
        }
        layer?.cornerRadius = cornerRadius
        layer?.borderWidth = borderColor == .clear ? 0 : 1
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// A static waveform inside a keycap: a brand mark, never an audio-level display.
/// The app icon is this same drawing on a forest tile (docs/assets/voxkey-icon.svg).
@MainActor
final class VoxKeyBrandMarkView: NSView {
    private let size: CGFloat

    init(size: CGFloat = 84) {
        self.size = size
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        setAccessibilityElement(false)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset = size * 0.06
        let key = bounds.insetBy(dx: inset, dy: inset)
        let shadow = key.offsetBy(dx: 0, dy: -size * 0.045)
        VoxKeyDesign.accentInk.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: shadow, xRadius: size * 0.23, yRadius: size * 0.23).fill()
        VoxKeyDesign.accent.setFill()
        NSBezierPath(roundedRect: key, xRadius: size * 0.23, yRadius: size * 0.23).fill()

        let inner = key.insetBy(dx: size * 0.075, dy: size * 0.075)
        NSColor.white.withAlphaComponent(0.60).setStroke()
        let rim = NSBezierPath(roundedRect: inner, xRadius: size * 0.16, yRadius: size * 0.16)
        rim.lineWidth = max(1, size * 0.009)
        rim.stroke()

        VoxKeyDesign.accentForeground.setFill()
        let heights: [CGFloat] = [0.18, 0.36, 0.51, 0.31, 0.17]
        let barWidth = size * 0.054
        let stride = size * 0.098
        for (index, height) in heights.enumerated() {
            let bar = NSRect(
                x: bounds.midX + CGFloat(index - 2) * stride - barWidth / 2,
                y: bounds.midY - size * height / 2,
                width: barWidth,
                height: size * height
            )
            NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
