import AppKit
import Testing
@testable import VoxKeyApp
import VoxKeyCore

@MainActor
@Test(arguments: [nil, .focusUnavailable, .unsupportedInsertion] as [DeliveryFailure?])
func completedDictationWithoutInputPreservesTextWithoutWarning(_ reason: DeliveryFailure?) async throws {
    _ = NSApplication.shared
    let sessionID = DictationSessionID()
    var machine = SessionStateMachine(phase: .finalizing(sessionID))
    try machine.beginDelivery(sessionID: sessionID, text: "A completed dictation")
    let coordinator = SessionCoordinator(initialState: machine)
    try await coordinator.finishWithoutDestination(sessionID: sessionID, reason: reason)
    var updates = await coordinator.updates.makeAsyncIterator()
    let snapshot = try #require(await updates.next())
    #expect(snapshot.phase == .ready)
    #expect(snapshot.lastResult?.text == "A completed dictation")
    #expect(snapshot.lastResult?.failure == nil)
    #expect(snapshot.lastResult?.deliveryUncertain == false)
    #expect(snapshot.attention == .dictationReady)

    let overlay = StatusOverlayController()
    overlay.update(snapshot)
    #expect(overlay.window?.isVisible == false)

}

@MainActor
@Test
func onlyDictationReadyAutomaticallyOpensTheTextPanel() throws {
    _ = NSApplication.shared
    let app = AppController()
    let result = LastResult(text: "A completed dictation")
    app.presentDictationIfNeeded(SessionSnapshot(
        phase: .ready, lastResult: result, attention: .deliveryBlocked(.destinationChanged)
    ))
    #expect(app.safetyNet == nil)
    let snapshot = SessionSnapshot(phase: .ready, lastResult: result, attention: .dictationReady)
    app.presentDictationIfNeeded(snapshot)
    let panel = try #require(app.safetyNet)
    defer { panel.closeAfterResolution() }
    #expect(panel.window?.isVisible == true)
    #expect(panel.window?.title == "Last Dictation")
    #expect(panel.result == snapshot.lastResult)
}

@MainActor
@Test(arguments: [
    DeliveryFailure.permissionsUnavailable, .selectionUnavailable, .inputBusy,
    .destinationUnavailable, .destinationChanged, .editingConflict,
    .secureDestination, .pasteboardChanged
])
func captureBlockersStillRequestWarning(_ reason: DeliveryFailure) async throws {
    _ = NSApplication.shared
    let sessionID = DictationSessionID()
    var machine = SessionStateMachine(phase: .finalizing(sessionID))
    try machine.beginDelivery(sessionID: sessionID, text: "Preserved text")
    let coordinator = SessionCoordinator(initialState: machine)
    try await coordinator.finishWithoutDestination(sessionID: sessionID, reason: reason)
    var updates = await coordinator.updates.makeAsyncIterator()
    let snapshot = try #require(await updates.next())
    #expect(snapshot.lastResult?.failure == reason)
    #expect(snapshot.attention == .deliveryBlocked(reason))
}
