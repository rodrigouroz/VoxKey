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

@MainActor
final class UpdateController: NSObject, SPUUpdaterDelegate, NSMenuItemValidation {
    let installation = UpdateInstallGate()
    private lazy var controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)

    func start() {
        // Command-line tests and local builds must not join the public update feed.
        guard Bundle.main.object(forInfoDictionaryKey: "VoxKeyReleaseBuild") as? Bool == true else { return }
        controller.startUpdater()
    }

    func addMenuItems(to menu: NSMenu) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        menu.addItem(NSMenuItem(title: "VoxKey \(version)", action: nil, keyEquivalent: ""))
        let check = NSMenuItem(title: installation.isWaiting ? "Update waiting for dictation recovery…" : "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
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
