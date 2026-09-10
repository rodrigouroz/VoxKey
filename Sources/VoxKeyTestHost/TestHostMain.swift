import AppKit
import WebKit

@main
@MainActor
struct VoxKeyTestHostMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = TestHostAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
private final class TestHostAppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler {
    private let nativeField = NSTextField(string: "Synthetic text before the caret.")
    private let nativeTextView = KeyboardPasteTextView()
    private let secureField = NSSecureTextField(string: "")
    private let webView = WKWebView()
    private let focusSink = NSButton(title: "Non-editor focus target", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "No conflict scheduled.")
    private var window: NSWindow?
    private var oracleTask: Task<Void, Never>?
    private var webText = ""
    private var oracleURL: URL?
    private var previousOracle: Data?
    private var scheduledMutation: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installApplicationMenu()
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--oracle-report"), args.count > index + 1 {
            oracleURL = URL(fileURLWithPath: args[index + 1])
        }
        webView.configuration.userContentController.add(self, name: "oracle")
        presentWindow()
        oracleTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.writeOracle()
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        scheduledMutation?.cancel()
        oracleTask?.cancel()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "oracle")
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "oracle", let text = message.body as? String else { return }
        webText = text
        writeOracle()
    }

    private func writeOracle() {
        guard let oracleURL else { return }
        // Read our own editor storage, never Accessibility. Secure input is excluded.
        let values: [String: String] = [
            "nativeField": nativeField.currentEditor()?.string ?? nativeField.stringValue,
            "nativeText": nativeTextView.string,
            "web": webText
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
              data != previousOracle else { return }
        do { try data.write(to: oracleURL, options: .atomic); previousOracle = data }
        catch { NSLog("Synthetic oracle write failed: %@", String(describing: error)) }
    }

    private func installApplicationMenu() {
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "VoxKey Test Host")
        applicationMenu.addItem(
            withTitle: "Quit VoxKey Test Host",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    private func presentWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 790),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "VoxKey Delivery Test Host"
        window.isReleasedWhenClosed = false
        window.center()
        window.minSize = NSSize(width: 680, height: 700)
        window.contentView = makeContentView()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeContentView() -> NSView {
        nativeField.placeholderString = "Native single-line field"
        nativeField.setAccessibilityLabel("Native single-line fixture")

        nativeTextView.string = "Synthetic first line.\nSynthetic second line."
        nativeTextView.font = .systemFont(ofSize: 14)
        nativeTextView.textContainerInset = NSSize(width: 8, height: 8)
        nativeTextView.setAccessibilityLabel("Native multiline fixture")
        let nativeScroll = NSScrollView()
        nativeScroll.borderType = .bezelBorder
        nativeScroll.hasVerticalScroller = true
        nativeScroll.documentView = nativeTextView
        nativeScroll.heightAnchor.constraint(equalToConstant: 92).isActive = true

        secureField.placeholderString = "Secure destination — capture must be rejected"
        secureField.setAccessibilityLabel("Secure destination fixture")
        focusSink.target = self
        focusSink.action = #selector(focusNonEditor)

        let webHTML = """
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8">
            <style>
              :root { color-scheme: light dark; }
              body { margin: 12px; font: 14px -apple-system, BlinkMacSystemFont, sans-serif; }
              #editor { min-height: 92px; border: 1px solid #8888; border-radius: 6px;
                        padding: 10px; outline: none; white-space: pre-wrap; }
              #editor:focus { border-color: #0a84ff; box-shadow: 0 0 0 2px #0a84ff44; }
            </style>
          </head>
          <body>
            <div id="editor" role="textbox" aria-label="Web contenteditable fixture"
                 aria-multiline="true" contenteditable="true">Synthetic web editor text.</div>
            <script>
              const editor = document.getElementById('editor');
              const report = () => window.webkit.messageHandlers.oracle.postMessage(editor.textContent);
              new MutationObserver(report).observe(editor, {subtree:true, childList:true, characterData:true});
              editor.addEventListener('input', report);
              report();
            </script>
          </body>
        </html>
        """
        webView.loadHTMLString(webHTML, baseURL: nil)
        webView.setAccessibilityLabel("Web-backed editor fixture")
        webView.heightAnchor.constraint(equalToConstant: 150).isActive = true

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 2

        let heading = NSTextField(labelWithString: "Controlled Text Delivery Fixtures")
        heading.font = .systemFont(ofSize: 24, weight: .bold)
        let instructions = NSTextField(wrappingLabelWithString:
            "Use synthetic speech only. Focus a fixture, hold Globe/Fn, speak, and release. " +
            "The delayed controls intentionally invalidate an Editing Intent while capture is active."
        )
        instructions.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [
            heading,
            instructions,
            sectionTitle("Native single-line editor"),
            nativeField,
            buttonRow([
                button("Reset and focus", #selector(resetNativeField)),
                button("Select “text”", #selector(selectNativeWord))
            ]),
            sectionTitle("Native multiline editor · keyboard paste"),
            nativeScroll,
            buttonRow([
                button("Reset and focus", #selector(resetNativeTextView))
            ]),
            sectionTitle("Web-backed contenteditable editor"),
            webView,
            buttonRow([
                button("Reset (then click editor)", #selector(resetWebEditor)),
                button("Empty paragraph (normalize on input)", #selector(resetEmptyWebParagraph))
            ]),
            sectionTitle("Security and unknown-destination fixtures"),
            secureField,
            focusSink,
            sectionTitle("Scheduled conflict controls"),
            buttonRow([
                button("In 3s: move caret", #selector(scheduleCaretMove)),
                button("In 3s: change text", #selector(scheduleTextChange))
            ]),
            buttonRow([
                button("In 3s: move focus", #selector(scheduleFocusChange)),
                button("In 3s: change clipboard", #selector(schedulePasteboardChange)),
                button("Cancel", #selector(cancelScheduledMutation))
            ]),
            statusLabel
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 24, right: 28)
        stack.translatesAutoresizingMaskIntoConstraints = false

        nativeField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -56).isActive = true
        nativeScroll.widthAnchor.constraint(equalTo: nativeField.widthAnchor).isActive = true
        webView.widthAnchor.constraint(equalTo: nativeField.widthAnchor).isActive = true
        secureField.widthAnchor.constraint(equalTo: nativeField.widthAnchor).isActive = true
        instructions.widthAnchor.constraint(equalTo: nativeField.widthAnchor).isActive = true

        let documentView = NSView()
        documentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor)
        ])

        let scrollView = NSScrollView()
        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        documentView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor)
        ])
        return scrollView
    }

    private func sectionTitle(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        return label
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func buttonRow(_ buttons: [NSButton]) -> NSStackView {
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    @objc private func resetNativeField() {
        nativeField.stringValue = "Synthetic text before the caret."
        focusNativeField(location: nativeField.stringValue.utf16.count)
    }

    @objc private func selectNativeWord() {
        resetNativeField()
        let range = (nativeField.stringValue as NSString).range(of: "text")
        nativeField.currentEditor()?.selectedRange = range
    }

    @objc private func resetNativeTextView() {
        nativeTextView.string = "Synthetic first line.\nSynthetic second line."
        window?.makeFirstResponder(nativeTextView)
        nativeTextView.setSelectedRange(NSRange(location: nativeTextView.string.utf16.count, length: 0))
    }

    @objc private func resetWebEditor() {
        webView.evaluateJavaScript(
            "(()=>{ const e=document.getElementById('editor'); e.oninput=null; e.textContent='Synthetic web editor text.'; " +
            "const r=document.createRange(); r.selectNodeContents(e); r.collapse(false); " +
            "const s=getSelection(); s.removeAllRanges(); s.addRange(r); })();"
        )
    }

    @objc private func resetEmptyWebParagraph() {
        webView.evaluateJavaScript(
            "(()=>{ const e=document.getElementById('editor'); e.innerHTML='<p><br></p>'; " +
            // Model a rich editor replacing its empty paragraph scaffold on the
            // first input. WebKit alone otherwise retains its terminal AX newline.
            "e.oninput=()=>{ if(!e.textContent)return; e.oninput=null; e.textContent=e.textContent; " +
            "const r=document.createRange(); r.selectNodeContents(e); r.collapse(false); " +
            "const s=getSelection(); s.removeAllRanges(); s.addRange(r); }; " +
            "const r=document.createRange(); r.setStart(e.firstChild, 0); r.collapse(true); " +
            "const s=getSelection(); s.removeAllRanges(); s.addRange(r); })();"
        )
    }

    @objc private func focusNonEditor() {
        window?.makeFirstResponder(focusSink)
    }

    @objc private func scheduleCaretMove() {
        schedule("Caret will move to the beginning in 3 seconds.") { [weak self] in
            self?.focusNativeField(location: 0)
        }
    }

    @objc private func scheduleTextChange() {
        schedule("Nearby text will change in 3 seconds.") { [weak self] in
            guard let self else { return }
            nativeField.stringValue += " [synthetic change]"
            focusNativeField(location: nativeField.stringValue.utf16.count)
        }
    }

    @objc private func scheduleFocusChange() {
        schedule("Focus will move to a non-editor in 3 seconds.") { [weak self] in
            self?.focusNonEditor()
        }
    }

    @objc private func schedulePasteboardChange() {
        schedule("The pasteboard will receive synthetic text in 3 seconds.") { [weak self] in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString("Synthetic concurrent clipboard change", forType: .string)
            self?.focusNativeField(location: self?.nativeField.stringValue.utf16.count ?? 0)
        }
    }

    @objc private func cancelScheduledMutation() {
        scheduledMutation?.cancel()
        scheduledMutation = nil
        statusLabel.stringValue = "No conflict scheduled."
    }

    private func schedule(_ message: String, action: @escaping @MainActor () -> Void) {
        scheduledMutation?.cancel()
        focusNativeField(location: nativeField.stringValue.utf16.count)
        statusLabel.stringValue = message + " Start a dictation now and keep speaking past the delay."
        scheduledMutation = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            action()
            self?.statusLabel.stringValue = "Scheduled synthetic change completed. VoxKey must use the Safety Net."
            self?.scheduledMutation = nil
        }
    }

    private func focusNativeField(location: Int) {
        window?.makeFirstResponder(nativeField)
        let boundedLocation = min(max(0, location), nativeField.stringValue.utf16.count)
        nativeField.currentEditor()?.selectedRange = NSRange(location: boundedLocation, length: 0)
    }
}

/// A real AppKit editor that supports keyboard paste while refusing direct AX
/// mutation. This exercises the production paste route without a web renderer.
@MainActor
private final class KeyboardPasteTextView: NSTextView {
    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if selector == #selector(setAccessibilitySelectedText(_:))
            || selector == #selector(setAccessibilityValue(_:)) {
            return false
        }
        return super.isAccessibilitySelectorAllowed(selector)
    }
}
