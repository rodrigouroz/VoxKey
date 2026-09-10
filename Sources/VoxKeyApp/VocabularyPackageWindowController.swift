import AppKit
import VoxKeyCore

@MainActor
final class VocabularyPackageWindowController: NSWindowController, NSSearchFieldDelegate {
    private let package: VocabularyPackage
    private let searchField = NSSearchField()
    private let contents = NSTextView()
    private let countLabel = VoxKeyDesign.label("", style: .caption, color: VoxKeyDesign.secondaryInk)

    init(package: VocabularyPackage) {
        self.package = package
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 580),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Package Contents"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        searchField.placeholderString = "Search terms, categories, or spoken forms"
        searchField.setAccessibilityLabel("Search package contents")
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self

        contents.isEditable = false
        contents.isSelectable = true
        contents.setAccessibilityLabel("Package terms, read only")
        let field = VoxKeyDesign.textField(contents, minimumHeight: 240)
        contents.frame = NSRect(x: 0, y: 0, width: 542, height: 240)
        // Long package entries wrap, and the full contents remain selectable for copying.
        contents.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        let done = NSButton(title: "Done", target: self, action: #selector(dismiss))
        done.keyEquivalent = "\r"
        VoxKeyDesign.configureButton(done, primary: true)
        let manifest = package.manifest
        let layout = VoxKeyDesign.vertical([
            VoxKeyDesign.label(manifest.displayName, style: .windowTitle),
            VoxKeyDesign.label("Version \(manifest.version) · English · \(manifest.classification)",
                               style: .caption, color: VoxKeyDesign.secondaryInk),
            searchField,
            field,
            VoxKeyDesign.horizontal([countLabel, NSView(), done])
        ])
        VoxKeyDesign.install(layout, in: window, fillsHeight: true)
        window.initialFirstResponder = searchField
        updateContents()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func controlTextDidChange(_ notification: Notification) { updateContents() }

    @objc private func dismiss() {
        guard let window else { return }
        window.sheetParent?.endSheet(window)
    }

    override func cancelOperation(_ sender: Any?) { dismiss() }

    private func updateContents() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let terms = package.terms.filter { term in
            query.isEmpty || ([term.canonical, term.category ?? ""] + (term.spokenForms ?? []))
                .contains { $0.localizedStandardContains(query) }
        }
        let text = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 5
        let body: [NSAttributedString.Key: Any] = [
            .font: VoxKeyDesign.TextStyle.caption.font,
            .foregroundColor: VoxKeyDesign.secondaryInk,
            .paragraphStyle: paragraph
        ]
        for term in terms {
            text.append(NSAttributedString(string: "\(term.canonical)\n", attributes: [
                .font: VoxKeyDesign.TextStyle.itemTitle.font,
                .foregroundColor: VoxKeyDesign.ink,
                .paragraphStyle: paragraph
            ]))
            let category = term.category.map { "Category: \($0) · " } ?? ""
            text.append(NSAttributedString(string: "\(category)Priority: \(term.priority)\n", attributes: body))
            if let forms = term.spokenForms, !forms.isEmpty {
                text.append(NSAttributedString(string: "Spoken forms: \(forms.joined(separator: ", "))\n", attributes: body))
            }
            text.append(NSAttributedString(string: "\n", attributes: body))
        }
        if terms.isEmpty {
            text.append(NSAttributedString(string: "No matching terms. Try a different search.", attributes: body))
        }
        contents.textStorage?.setAttributedString(text)
        contents.setSelectedRange(NSRange(location: 0, length: 0))
        contents.scroll(.zero)
        countLabel.stringValue = query.isEmpty
            ? "\(terms.count) terms · Read only"
            : "\(terms.count) of \(package.terms.count) terms · Read only"
    }
}
