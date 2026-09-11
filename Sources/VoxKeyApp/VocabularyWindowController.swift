import AppKit
import VoxKeyCore

@MainActor
final class VocabularyWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    private let store: VocabularyStore
    private let activationCoordinator = ApplicationActivationCoordinator()
    private let personalEditor = NSTextView()
    private let status = VoxKeyDesign.label("", style: .caption, color: VoxKeyDesign.secondaryInk)
    private let packagePicker = NSPopUpButton()
    private let packageDetails = VoxKeyDesign.label("", style: .caption, color: VoxKeyDesign.secondaryInk)
    private let activeButton = NSButton(checkboxWithTitle: "Use this package", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let viewContentsButton = NSButton(title: "View Contents…", target: nil, action: nil)
    private var packageViewer: VocabularyPackageWindowController?

    init(store: VocabularyStore) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 656, height: 724),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Vocabulary"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self

        personalEditor.string = store.personalTerms.joined(separator: "\n")
        personalEditor.isAutomaticQuoteSubstitutionEnabled = false
        personalEditor.isAutomaticDashSubstitutionEnabled = false
        personalEditor.isAutomaticSpellingCorrectionEnabled = false
        personalEditor.isHorizontallyResizable = false
        personalEditor.isVerticallyResizable = true
        personalEditor.autoresizingMask = [.width]
        personalEditor.textContainer?.widthTracksTextView = true
        personalEditor.setAccessibilityLabel("Personal vocabulary, one term per line")
        personalEditor.delegate = self
        let field = VoxKeyDesign.textField(personalEditor, minimumHeight: 156)
        field.heightAnchor.constraint(equalToConstant: 156).isActive = true
        personalEditor.frame = NSRect(x: 0, y: 0, width: 560, height: 154)

        let save = NSButton(title: "Save Terms", target: self, action: #selector(saveTerms))
        VoxKeyDesign.configureButton(save, primary: true)
        let saveRow = row([status, NSView(), save])
        let personal = VoxKeyDesign.section([
            VoxKeyDesign.label("Personal terms", style: .sectionTitle),
            VoxKeyDesign.label("One name, acronym, or phrase per line. Up to 200 terms; your terms take priority.", style: .caption, color: VoxKeyDesign.secondaryInk),
            field, saveRow
        ])

        packagePicker.target = self
        packagePicker.action = #selector(selectPackage)
        packagePicker.setAccessibilityLabel("Imported vocabulary packages")
        activeButton.target = self
        activeButton.action = #selector(togglePackage)
        removeButton.target = self
        removeButton.action = #selector(removePackage)
        VoxKeyDesign.configureButton(removeButton)
        let importButton = NSButton(title: "Import Package…", target: self, action: #selector(choosePackage))
        VoxKeyDesign.configureButton(importButton)
        viewContentsButton.target = self
        viewContentsButton.action = #selector(viewPackageContents)
        VoxKeyDesign.configureButton(viewContentsButton)
        let packageActions = row([activeButton, NSView(), removeButton, importButton])
        let packages = VoxKeyDesign.section([
            VoxKeyDesign.label("Vocabulary packages", style: .sectionTitle),
            row([packagePicker, viewContentsButton]), packageDetails, packageActions
        ])

        let introduction = column([
            VoxKeyDesign.label("Your vocabulary", style: .windowTitle),
            VoxKeyDesign.label("Help VoxKey recognize the names and terms you use. Vocabulary stays on this Mac.", style: .body, color: VoxKeyDesign.secondaryInk)
        ], spacing: 8)
        let content = column([
            introduction, personal, packages,
            VoxKeyDesign.label("Changes apply to your next dictation. A selection of terms guides recognition; spelling is not guaranteed.", style: .caption, color: VoxKeyDesign.secondaryInk)
        ], spacing: VoxKeyDesign.Layout.sectionSpacing)
        VoxKeyDesign.install(content, in: window)
        refreshPackages()
        status.stringValue = "\(store.personalTerms.count) personal \(store.personalTerms.count == 1 ? "term" : "terms")"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        showWindow(nil)
        window?.orderFrontRegardless()
        activationCoordinator.present { [weak window] in
            guard window?.isVisible == true else { return }
            window?.makeKeyAndOrderFront(nil)
        }
    }

    func windowWillClose(_ notification: Notification) { activationCoordinator.restorePreviousApplication() }
    func textDidChange(_ notification: Notification) { status.stringValue = "Unsaved changes" }

    @objc private func saveTerms() {
        do {
            try store.savePersonalTerms(personalEditor.string)
            personalEditor.string = store.personalTerms.joined(separator: "\n")
            status.stringValue = "Saved · \(store.personalTerms.count) personal \(store.personalTerms.count == 1 ? "term" : "terms")"
        } catch { showError(error) }
    }

    private var selectedPackage: VocabularyStore.InstalledPackage? {
        let index = packagePicker.indexOfSelectedItem
        return store.packages.indices.contains(index) ? store.packages[index] : nil
    }

    private func refreshPackages(selecting identifier: String? = nil) {
        packagePicker.removeAllItems()
        packagePicker.addItems(withTitles: store.packages.map { "\($0.package.manifest.displayName) · \($0.package.manifest.version)" })
        if let identifier, let index = store.packages.firstIndex(where: { $0.package.manifest.identifier == identifier }) {
            packagePicker.selectItem(at: index)
        }
        packagePicker.isEnabled = !store.packages.isEmpty
        if store.packages.isEmpty { packagePicker.addItem(withTitle: "No packages imported") }
        selectPackage()
    }

    @objc private func selectPackage() {
        let selected = selectedPackage
        activeButton.isEnabled = selected != nil
        removeButton.isEnabled = selected != nil
        viewContentsButton.isHidden = selected == nil
        activeButton.state = selected?.active == true ? .on : .off
        if let selected {
            let package = selected.package
            packageDetails.stringValue = "\(package.terms.count) \(package.terms.count == 1 ? "term" : "terms") · English · \(package.manifest.classification)\n\(selected.active ? "Active for new dictations." : "Imported and inactive. Turn on Use this package to activate it.")"
        } else {
            packageDetails.stringValue = "Import a vocabulary ZIP, package folder, or manifest.json file.\nReview its details before turning it on."
        }
    }

    @objc private func viewPackageContents() {
        guard let window, let selected = selectedPackage, window.attachedSheet == nil else { return }
        let viewer = VocabularyPackageWindowController(package: selected.package)
        guard let sheet = viewer.window else { return }
        packageViewer = viewer
        window.beginSheet(sheet) { [weak self] _ in self?.packageViewer = nil }
    }

    @objc private func togglePackage() {
        guard let selected = selectedPackage else { return }
        do { try store.setActive(activeButton.state == .on, identifier: selected.package.manifest.identifier) }
        catch { showError(error) }
        selectPackage()
    }

    @objc private func removePackage() {
        guard let selected = selectedPackage else { return }
        do {
            try store.removePackage(identifier: selected.package.manifest.identifier)
            refreshPackages()
        } catch { showError(error) }
    }

    @objc private func choosePackage() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Review Package"
        panel.message = "Choose a vocabulary ZIP, package folder, or manifest.json file."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do { reviewPackage(try VocabularyStore.previewPackage(at: url)) }
            catch { showError(error) }
        }
    }

    private func reviewPackage(_ package: VocabularyPackage) {
        guard let window else { return }
        let manifest = package.manifest
        let replacing = store.packages.contains { $0.package.manifest.identifier == manifest.identifier }
        let alert = NSAlert()
        alert.messageText = manifest.displayName
        alert.informativeText = "Version \(manifest.version) · \(package.terms.count) \(package.terms.count == 1 ? "term" : "terms")\nEnglish · \(manifest.classification)\n\n\(replacing ? "This replaces the imported version and turns it off." : "The package will be imported inactive.") Turn on Use this package when you’re ready."
        alert.addButton(withTitle: replacing ? "Replace Package" : "Import Package")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            do {
                try store.importPackage(package)
                refreshPackages(selecting: manifest.identifier)
            } catch { showError(error) }
        }
    }

    private func showError(_ error: Error) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Vocabulary couldn’t be updated"
        alert.informativeText = (error as? VocabularyError)?.localizedDescription ?? "The change could not be saved. Check that VoxKey can write to Application Support and try again."
        alert.beginSheetModal(for: window)
    }

    private func column(_ views: [NSView], spacing: CGFloat = VoxKeyDesign.Layout.contentSpacing) -> NSStackView {
        VoxKeyDesign.vertical(views, spacing: spacing)
    }

    private func row(_ views: [NSView]) -> NSStackView {
        VoxKeyDesign.horizontal(views)
    }
}
