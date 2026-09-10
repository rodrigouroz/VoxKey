import AppKit
import VoxKeyCore

@MainActor
final class SafetyNetWindowController: NSWindowController, NSWindowDelegate {
    var onDeliver: ((LastResult) -> Void)?
    var onCopy: ((LastResult) -> Void)?
    var onDismiss: ((UUID) -> Void)?
    private(set) var result: LastResult
    private let heading = VoxKeyDesign.label("", style: .windowTitle)
    private let eyebrow = VoxKeyDesign.eyebrow("")

    private let destinationLabel = VoxKeyDesign.label("", style: .caption, color: VoxKeyDesign.secondaryInk)
    private let destinationIcon = NSImageView()
    private let textView = NSTextView()
    private let copyButton = NSButton(title: "Copy (⌘C)", target: nil, action: nil)
    private let deliverButton = NSButton(title: "Deliver", target: nil, action: nil)
    private var keyMonitor: Any?
    private var dismissingProgrammatically = false
    private let activationCoordinator: ApplicationActivationCoordinator
    private let checkedDestination = NSButton(checkboxWithTitle: "I checked the input; insert this text again", target: nil, action: nil)
    private let uncertaintyCard = VoxKeyCardView(fill: VoxKeyDesign.warmWash)
    private var hasDestination = false
    private var deliveryInFlight = false

    init(
        result: LastResult,
        destination: DestinationLabel?,
        activationCoordinator: ApplicationActivationCoordinator = ApplicationActivationCoordinator()
    ) {
        self.activationCoordinator = activationCoordinator
        self.result = result
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 584, height: 576),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = result.failure == nil ? "Last Dictation" : "VoxKey Safety Net"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)

        let header = VoxKeyDesign.vertical([
            eyebrow, heading,
            VoxKeyDesign.label("Kept on this Mac for this session.", style: .caption, color: VoxKeyDesign.secondaryInk)
        ], spacing: 8)

        destinationIcon.imageScaling = .scaleProportionallyDown
        destinationIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            destinationIcon.widthAnchor.constraint(equalToConstant: 24),
            destinationIcon.heightAnchor.constraint(equalToConstant: 24)
        ])
        let destinationRow = NSStackView(views: [destinationIcon, destinationLabel])
        destinationRow.orientation = .horizontal
        destinationRow.alignment = .centerY
        destinationRow.spacing = 9

        textView.string = result.text
        textView.isEditable = false
        textView.isSelectable = true
        textView.minSize = NSSize(width: 0, height: 132)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("Last dictation")
        textView.frame = NSRect(x: 0, y: 0, width: 488, height: 132)
        let field = VoxKeyDesign.textField(textView, minimumHeight: 132)
        let divider = VoxKeyCardView(fill: VoxKeyDesign.border, border: .clear, cornerRadius: 0)
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let transcriptCard = VoxKeyDesign.section([field, divider, destinationRow])

        VoxKeyDesign.configureButton(copyButton)
        VoxKeyDesign.configureButton(deliverButton, primary: true)
        deliverButton.keyEquivalent = "\r"
        deliverButton.isEnabled = destination != nil
        let dismiss = NSButton(title: "Dismiss", target: nil, action: nil)
        VoxKeyDesign.configureButton(dismiss)
        let actions = NSStackView(views: [dismiss, NSView(), copyButton, deliverButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 10
        deliverButton.target = self
        deliverButton.action = #selector(deliver)
        copyButton.target = self
        copyButton.action = #selector(copyResult)
        dismiss.target = self
        dismiss.action = #selector(dismissResult)

        checkedDestination.target = self
        checkedDestination.action = #selector(confirmDestinationChecked)
        checkedDestination.font = VoxKeyDesign.TextStyle.caption.font
        checkedDestination.contentTintColor = VoxKeyDesign.ink
        checkedDestination.isHidden = !result.deliveryUncertain
        let uncertaintyNote = VoxKeyDesign.label(
            "This text may already be in your input. Check it before delivering again.",
            style: .caption, color: VoxKeyDesign.warm
        )
        let uncertaintyContent = NSStackView(views: [uncertaintyNote, checkedDestination])
        uncertaintyContent.orientation = .vertical
        uncertaintyContent.alignment = .leading
        uncertaintyContent.spacing = 9
        VoxKeyDesign.embed(uncertaintyContent, in: uncertaintyCard)
        uncertaintyNote.widthAnchor.constraint(equalTo: uncertaintyContent.widthAnchor).isActive = true
        uncertaintyCard.isHidden = !result.deliveryUncertain

        let content = VoxKeyDesign.vertical([
            header, transcriptCard, uncertaintyCard, actions
        ], spacing: VoxKeyDesign.Layout.sectionSpacing)
        VoxKeyDesign.install(content, in: window, fillsHeight: true)

        window.delegate = self
        updateHeading()
        updateDestination(destination)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true,
                  event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers?.lowercased() == "c" else { return event }
            self.copyResult()
            return nil
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateDestination(_ destination: DestinationLabel?) {
        hasDestination = destination != nil
        if let destination {
            destinationLabel.stringValue = "Return will deliver to \(destination.applicationName)"
            destinationIcon.image = NSRunningApplication(processIdentifier: destination.processIdentifier)?.icon
        } else {
            destinationLabel.stringValue = "Copy your text, or focus an input and choose Recover Dictation… from the VoxKey menu to insert it."
            destinationIcon.image = NSImage(systemSymbolName: "text.cursor", accessibilityDescription: nil)
        }
        VoxKeyDesign.configureButton(copyButton, primary: !hasDestination)
        deliverButton.isHidden = !hasDestination
        destinationIcon.contentTintColor = hasDestination ? nil : VoxKeyDesign.secondaryInk
        refreshDeliverButton()
    }

    func updateResult(_ result: LastResult) {
        guard self.result != result else { return }
        self.result = result
        window?.title = result.failure == nil ? "Last Dictation" : "VoxKey Safety Net"
        updateHeading()
        textView.string = result.text
        checkedDestination.state = .off
        checkedDestination.isHidden = !result.deliveryUncertain
        uncertaintyCard.isHidden = !result.deliveryUncertain
        if !hasDestination { updateDestination(nil) }
        refreshDeliverButton()
    }

    func setDeliveryInFlight(_ inFlight: Bool) {
        deliveryInFlight = inFlight
        refreshDeliverButton()
    }

    private func updateHeading() {
        let ready = result.failure == nil && !result.deliveryUncertain
        heading.stringValue = ready ? "Your dictation is ready." : "Your words are still here."
        eyebrow.stringValue = result.failure == nil ? "LAST DICTATION" : "SAFETY NET"
    }

    private func refreshDeliverButton() {
        deliverButton.isEnabled = hasDestination && !deliveryInFlight
            && (!result.deliveryUncertain || checkedDestination.state == .on)
    }

    @objc private func confirmDestinationChecked() { refreshDeliverButton() }

    func present() {
        showWindow(nil)
        window?.orderFrontRegardless()
        activationCoordinator.present { [weak window] in
            guard window?.isVisible == true else { return }
            window?.makeKeyAndOrderFront(nil)
        }
    }

    func closeAfterResolution() {
        dismissingProgrammatically = true
        close()
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        activationCoordinator.restorePreviousApplication()
        if !dismissingProgrammatically { onDismiss?(result.id) }
    }

    @objc private func deliver() {
        guard deliverButton.isEnabled else { return }
        setDeliveryInFlight(true)
        onDeliver?(result)
    }
    @objc private func copyResult() {
        guard !deliveryInFlight else { return }
        onCopy?(result)
    }
    @objc private func dismissResult() {
        guard !deliveryInFlight else { return }
        onDismiss?(result.id)
        closeAfterResolution()
    }
}
