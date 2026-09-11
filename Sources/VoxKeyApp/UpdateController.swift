import AppKit
import Sparkle
import VoxKeyCore

/// Retains Sparkle's continuation while dictation or unresolved recovery owns the app.
@MainActor
final class UpdateInstallGate {
    private var snapshot = SessionSnapshot(phase: .notReady(.onboarding), lastResult: nil)
    private var installHandler: (() -> Void)?

    var isWaiting: Bool { installHandler != nil }
    var canCheckForUpdates: Bool { !snapshot.phase.isBusy }
    var canInstall: Bool {
        !snapshot.phase.isBusy && snapshot.attention != .dictationReady
            && snapshot.lastResult?.failure == nil
            && snapshot.lastResult?.deliveryUncertain != true
    }

    func update(_ snapshot: SessionSnapshot) {
        self.snapshot = snapshot
        guard canInstall, let installHandler else { return }
        self.installHandler = nil
        installHandler()
    }

    func postponeIfNeeded(_ installHandler: @escaping () -> Void) -> Bool {
        guard !canInstall else { return false }
        self.installHandler = installHandler
        return true
    }
}

// Sparkle's Objective-C UI delegate runs on the main thread but lacks actor annotations.
@MainActor
final class UpdateController: NSObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate, NSMenuItemValidation {
    let installation = UpdateInstallGate()
    private lazy var controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
    private weak var statusItem: NSStatusItem?
    private var availableVersion: String?

    func attachReminder(to statusItem: NSStatusItem) {
        self.statusItem = statusItem
        refreshReminder()
    }

    private func refreshReminder() {
        // Keep the dictation icon intact and add a persistent, accessible reminder.
        statusItem?.button?.title = availableVersion == nil ? "" : " Update"
        statusItem?.button?.imagePosition = availableVersion == nil ? .imageOnly : .imageLeading
        statusItem?.button?.toolTip = availableVersion.map { "VoxKey \($0) is available. Open the menu to update." }
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        // Setup temporarily hides the status item and puts VoxKey in the Dock;
        // let Sparkle use its normal foreground-app presentation in that case.
        (immediateFocus || statusItem?.isVisible == false) && installation.canInstall
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        availableVersion = update.displayVersionString
        refreshReminder()
    }

    func standardUserDriverWillFinishUpdateSession() {
        availableVersion = nil
        refreshReminder()
    }

    func start() {
        // Command-line tests and local builds must not join the public update feed.
        guard Bundle.main.object(forInfoDictionaryKey: "VoxKeyReleaseBuild") as? Bool == true else { return }
        controller.updater.sendsSystemProfile = false
        controller.startUpdater()
    }

    func addMenuItems(to menu: NSMenu) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        menu.addItem(NSMenuItem(title: "VoxKey \(version)", action: nil, keyEquivalent: ""))
        let title = if installation.isWaiting {
            "Update waiting for dictation recovery…"
        } else if let availableVersion {
            "Update to VoxKey \(availableVersion)…"
        } else {
            "Check for Updates…"
        }
        let check = NSMenuItem(title: title, action: #selector(checkForUpdates), keyEquivalent: "")
        check.target = self
        check.isEnabled = controller.updater.canCheckForUpdates && installation.canCheckForUpdates
        menu.addItem(check)

        let automatic = NSMenuItem(title: "Automatically Check for Updates", action: #selector(toggleAutomaticChecks), keyEquivalent: "")
        automatic.target = self
        automatic.state = controller.updater.automaticallyChecksForUpdates ? .on : .off
        automatic.isEnabled = Bundle.main.object(forInfoDictionaryKey: "VoxKeyReleaseBuild") as? Bool == true
        menu.addItem(automatic)
    }

    @objc private func checkForUpdates() {
        guard installation.canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }

    @objc private func toggleAutomaticChecks() {
        controller.updater.automaticallyChecksForUpdates.toggle()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // NSMenu's automatic validation otherwise overrides isEnabled on our items.
        guard Bundle.main.object(forInfoDictionaryKey: "VoxKeyReleaseBuild") as? Bool == true else { return false }
        if menuItem.action == #selector(checkForUpdates) {
            return controller.updater.canCheckForUpdates && installation.canCheckForUpdates
        }
        return menuItem.action == #selector(toggleAutomaticChecks)
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard installation.canCheckForUpdates else {
            throw NSError(domain: "com.rodrigouroz.VoxKey.Updates", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Finish dictating before checking for updates."])
        }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        installation.postponeIfNeeded(installHandler)
    }
}
