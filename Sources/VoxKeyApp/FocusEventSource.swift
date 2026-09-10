@preconcurrency import AppKit
import ApplicationServices
import OSLog

@MainActor
protocol FocusEventSource: AnyObject {
    var onFocusEvent: ((AXUIElement, AccessibilityProcessIdentity) -> Void)? { get set }
    func start()
}

@MainActor
final class NoopFocusEventSource: FocusEventSource {
    var onFocusEvent: ((AXUIElement, AccessibilityProcessIdentity) -> Void)?

    func start() {}
}

@MainActor
final class SystemFocusEventSource: NSObject, FocusEventSource {
    var onFocusEvent: ((AXUIElement, AccessibilityProcessIdentity) -> Void)?

    private let logger = Logger(subsystem: "com.rodrigouroz.VoxKey", category: "focus")
    private var started = false
    private var observer: AXObserver?
    private var runLoopSource: CFRunLoopSource?
    private var applicationElement: AXUIElement?
    private var process: AccessibilityProcessIdentity?

    func start() {
        guard !started else { return }
        started = true
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidActivate),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        if let application = NSWorkspace.shared.frontmostApplication {
            observe(application)
        }
    }

    isolated deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
    }

    @objc private func applicationDidActivate(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else { return }
        observe(application)
    }

    private func observe(_ application: NSRunningApplication) {
        let identity = AccessibilityProcessIdentity(
            processIdentifier: application.processIdentifier,
            launchDate: application.launchDate
        )
        if process == identity, observer != nil, let applicationElement {
            onFocusEvent?(applicationElement, identity)
            return
        }

        stopObservingApplication()
        let element = AXUIElementCreateApplication(identity.processIdentifier)
        applicationElement = element
        process = identity

        var createdObserver: AXObserver?
        let createResult = AXObserverCreate(
            identity.processIdentifier,
            { _, _, notification, refcon in
                guard let refcon else { return }
                let source = Unmanaged<SystemFocusEventSource>
                    .fromOpaque(refcon)
                    .takeUnretainedValue()
                let notificationName = notification as String
                Task { @MainActor in
                    source.handle(notificationName)
                }
            },
            &createdObserver
        )
        guard createResult == .success, let createdObserver else {
            logger.notice(
                "focus observer unavailable pid=\(identity.processIdentifier, privacy: .public) ax_error=\(createResult.rawValue, privacy: .public)"
            )
            onFocusEvent?(element, identity)
            return
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notificationName in [
            kAXFocusedUIElementChangedNotification,
            kAXFocusedWindowChangedNotification,
            kAXApplicationActivatedNotification
        ] {
            let result = AXObserverAddNotification(
                createdObserver,
                element,
                notificationName as CFString,
                refcon
            )
            if result != .success && result != .notificationAlreadyRegistered {
                logger.notice(
                    "focus observer registration failed pid=\(identity.processIdentifier, privacy: .public) ax_error=\(result.rawValue, privacy: .public)"
                )
            }
        }

        let source = AXObserverGetRunLoopSource(createdObserver)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        observer = createdObserver
        runLoopSource = source
        onFocusEvent?(element, identity)
    }

    private func handle(_ notificationName: String) {
        guard notificationName == kAXFocusedUIElementChangedNotification
                || notificationName == kAXFocusedWindowChangedNotification
                || notificationName == kAXApplicationActivatedNotification,
              let applicationElement,
              let process else { return }
        logger.debug(
            "focus event received pid=\(process.processIdentifier, privacy: .public)"
        )
        onFocusEvent?(applicationElement, process)
    }

    private func stopObservingApplication() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        observer = nil
        runLoopSource = nil
        applicationElement = nil
        process = nil
    }
}
