import AppKit
import Sparkle
import Testing
import VoxKeyCore
@testable import VoxKeyApp

@MainActor @Test
func updaterSupportsVisibleScheduledReminders() throws {
    let updates: AnyObject = UpdateController()
    let delegate = try #require(updates as? any SPUStandardUserDriverDelegate)
    #expect(delegate.supportsGentleScheduledUpdateReminders == true)
}

@MainActor @Test(arguments: [false, true])
func updateReminderShowsVersionAndClearsWhenSparkleFinishes(userInitiated: Bool) throws {
    _ = NSApplication.shared
    let updates = UpdateController()
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    defer { NSStatusBar.system.removeStatusItem(item) }
    let icon = VoxKeyDesign.menuBarMark()
    item.button?.image = icon
    updates.attachReminder(to: item)
    #expect(item.button?.title == "")

    let update = try reminderUpdate()
    updates.standardUserDriverWillHandleShowingUpdate(userInitiated, forUpdate: update,
                                                      state: try reminderState(userInitiated: userInitiated))
    #expect(item.button?.title == " Update")
    #expect(item.button?.image === icon)
    #expect(item.button?.imagePosition == .imageLeading)
    #expect(item.button?.toolTip?.contains("0.6.0") == true)
    let menu = NSMenu()
    updates.addMenuItems(to: menu)
    let action = try #require(menu.items.first { $0.title == "Update to VoxKey 0.6.0…" })
    #expect(action.target === updates)
    #expect(action.action == NSSelectorFromString("checkForUpdates"))

    // Attention alone must not remove the user's route back to an open alert.
    // Sparkle finishes the session on dismiss, skip, or an update error.
    updates.standardUserDriverWillFinishUpdateSession()
    #expect(item.button?.title == "")
    #expect(item.button?.image === icon)
    #expect(item.button?.imagePosition == .imageOnly)
    #expect(item.button?.toolTip == nil)
    menu.removeAllItems()
    updates.addMenuItems(to: menu)
    #expect(menu.items.contains { $0.title == "Check for Updates…" })
    #expect(!menu.items.contains { $0.title.hasPrefix("Update to") })
}

@MainActor @Test
func scheduledUpdateFocusRespectsDictationAndRecovery() throws {
    _ = NSApplication.shared
    let updates = UpdateController()
    let update = try reminderUpdate()
    updates.installation.update(.init(phase: .ready, lastResult: nil))
    #expect(updates.standardUserDriverShouldHandleShowingScheduledUpdate(update, andInImmediateFocus: true))
    #expect(!updates.standardUserDriverShouldHandleShowingScheduledUpdate(update, andInImmediateFocus: false))

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    defer { NSStatusBar.system.removeStatusItem(item) }
    updates.attachReminder(to: item)
    item.isVisible = false
    #expect(updates.standardUserDriverShouldHandleShowingScheduledUpdate(update, andInImmediateFocus: false))
    item.isVisible = true

    updates.installation.update(.init(phase: .capturing(DictationSessionID()), lastResult: nil))
    #expect(!updates.standardUserDriverShouldHandleShowingScheduledUpdate(update, andInImmediateFocus: true))
    updates.installation.update(.init(phase: .ready, lastResult: .init(text: "Synthetic result", deliveryUncertain: true)))
    #expect(!updates.standardUserDriverShouldHandleShowingScheduledUpdate(update, andInImmediateFocus: true))
    updates.standardUserDriverWillHandleShowingUpdate(false, forUpdate: update, state: try reminderState(userInitiated: false))
    #expect(updates.installation.postponeIfNeeded {})
    let menu = NSMenu()
    updates.addMenuItems(to: menu)
    #expect(menu.items.contains { $0.title == "Update waiting for dictation recovery…" })
}

private func reminderUpdate() throws -> SUAppcastItem {
    // The fixture needs display metadata only, not Sparkle's system eligibility resolver.
    try #require(SUAppcastItem(dictionary: [
        "sparkle:version": "13",
        "sparkle:shortVersionString": "0.6.0",
        "enclosure": ["url": "https://example.invalid/VoxKey.dmg"]
    ]))
}

private func reminderState(userInitiated: Bool) throws -> SPUUserUpdateState {
    // Sparkle exposes NSSecureCoding but no public state-construction initializer.
    let archive = NSKeyedArchiver(requiringSecureCoding: true)
    archive.encode(SPUUserUpdateStage.notDownloaded.rawValue, forKey: "SPUUserUpdateStateStage")
    archive.encode(userInitiated, forKey: "SPUUserUpdateStateUserInitiated")
    archive.finishEncoding()
    let decoder = try NSKeyedUnarchiver(forReadingFrom: archive.encodedData)
    defer { decoder.finishDecoding() }
    return try #require(SPUUserUpdateState(coder: decoder))
}
