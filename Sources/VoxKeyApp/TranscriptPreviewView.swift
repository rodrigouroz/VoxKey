import AppKit
import QuartzCore

/// Noninteractive captions. Only the latest three lines are visible; the text
/// itself is already bounded by the session before it reaches the main actor.
@MainActor
final class TranscriptPreviewView: NSView {
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private var textChanged = false
    private var contentHeight: CGFloat = 0
    private var viewportHeight: CGFloat = 0
    private var provisionalLength = 0
    private static let lineHeight: CGFloat = 21

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = textView
        addSubview(scrollView)

        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.setAccessibilityLabel("Live transcript")
        textView.setAccessibilityRole(.staticText)
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        // Follow the window's actual height during expansion. The caption clip
        // always starts below the header, even between animation frames.
        scrollView.frame = NSRect(x: 0, y: min(16, bounds.height), width: bounds.width,
                                  height: max(0, bounds.height - 16))
    }

    func setText(_ confirmed: String, provisional: String? = nil) {
        let draft = provisional ?? ""
        let text = String([confirmed, draft].filter { !$0.isEmpty }.joined(separator: " ").suffix(1_200))
        let draftLength = min(text.utf16.count, draft.utf16.count)
        guard textView.string != text || draftLength != provisionalLength else { return }
        provisionalLength = draftLength
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = Self.lineHeight
        paragraph.maximumLineHeight = Self.lineHeight
        paragraph.lineBreakMode = .byWordWrapping
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: VoxKeyDesign.TextStyle.body.font,
            .foregroundColor: VoxKeyDesign.Overlay.ink,
            .paragraphStyle: paragraph
        ])
        if draftLength > 0 {
            attributed.addAttribute(.foregroundColor, value: VoxKeyDesign.Overlay.secondaryInk,
                                    range: NSRange(location: attributed.length - draftLength, length: draftLength))
        }
        textView.textStorage?.setAttributedString(attributed)
        textChanged = true
    }

    func prepareLayout(width: CGFloat) -> CGFloat {
        guard let container = textView.textContainer, let layout = textView.layoutManager else { return 0 }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        contentHeight = ceil(layout.usedRect(for: container).height)
        textView.setFrameSize(NSSize(width: width, height: contentHeight))
        viewportHeight = min(Self.lineHeight * 3, contentHeight)
        return viewportHeight
    }

    func revealLatest(animated: Bool) {
        layoutSubtreeIfNeeded()
        guard textChanged else { return }
        textChanged = false
        let clip = scrollView.contentView
        let destination = NSPoint(x: 0, y: max(0, contentHeight - viewportHeight))
        if animated, destination != clip.bounds.origin {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                clip.animator().setBoundsOrigin(destination)
            }
        } else {
            clip.setBoundsOrigin(destination)
        }
        scrollView.reflectScrolledClipView(clip)
    }

    func clear() {
        textView.string = ""
        contentHeight = 0
        textChanged = false
        provisionalLength = 0
        layer?.removeAllAnimations()
        scrollView.contentView.setBoundsOrigin(.zero)
    }
}
