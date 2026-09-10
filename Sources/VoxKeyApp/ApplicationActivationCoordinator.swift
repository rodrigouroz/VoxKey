import AppKit

@MainActor
final class ApplicationActivationCoordinator: NSObject {
    private let ownProcessIdentifier: pid_t
    private let isActive: () -> Bool
    private let currentProcessIdentifier: () -> pid_t?
    private let requestActivation: (pid_t?) -> Void
    private let restoreActivation: (pid_t) -> Void

    private var processIdentifierToRestore: pid_t?
    private var pendingPresentation: (() -> Void)?

    init(
        ownProcessIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier,
        isActive: @escaping () -> Bool = { NSApp.isActive },
        currentProcessIdentifier: @escaping () -> pid_t? = {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        },
        requestActivation: @escaping (pid_t?) -> Void = { sourceProcessIdentifier in
            let application = NSRunningApplication.current
            if let sourceProcessIdentifier,
               let source = NSRunningApplication(processIdentifier: sourceProcessIdentifier) {
                if !application.activate(from: source, options: []) {
                    NSApp.activate()
                }
            } else {
                NSApp.activate()
            }
        },
        restoreActivation: @escaping (pid_t) -> Void = { processIdentifier in
            guard let destination = NSRunningApplication(processIdentifier: processIdentifier) else { return }
            let application = NSRunningApplication.current
            NSApp.yieldActivation(to: destination)
            _ = destination.activate(from: application, options: [])
        }
    ) {
        self.ownProcessIdentifier = ownProcessIdentifier
        self.isActive = isActive
        self.currentProcessIdentifier = currentProcessIdentifier
        self.requestActivation = requestActivation
        self.restoreActivation = restoreActivation
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: NSApp
        )
    }

    func present(makeKeyAndOrderFront: @escaping () -> Void) {
        captureApplicationToRestore()
        pendingPresentation = makeKeyAndOrderFront
        if isActive() {
            applicationDidBecomeActive()
        } else {
            requestActivation(processIdentifierToRestore)
        }
    }

    func applicationDidBecomeActive() {
        guard isActive(), let pendingPresentation else { return }
        self.pendingPresentation = nil
        pendingPresentation()
    }

    func restorePreviousApplication() {
        pendingPresentation = nil
        guard let processIdentifierToRestore else { return }
        self.processIdentifierToRestore = nil
        guard isActive() else { return }
        restoreActivation(processIdentifierToRestore)
    }

    private func captureApplicationToRestore() {
        guard processIdentifierToRestore == nil,
              let currentProcessIdentifier = currentProcessIdentifier(),
              currentProcessIdentifier != ownProcessIdentifier else { return }
        processIdentifierToRestore = currentProcessIdentifier
    }

    @objc private func didBecomeActive(_ notification: Notification) {
        applicationDidBecomeActive()
    }
}
