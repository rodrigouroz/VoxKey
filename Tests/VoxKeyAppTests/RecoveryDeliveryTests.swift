import Foundation
import Testing
@testable import VoxKeyApp
import VoxKeyCore

@MainActor
@Test
func aQuickReleaseDuringArmingNeverOpensTheMicrophone() async {
    let fixture = DesktopFixture()
    let sessionID = DictationSessionID()
    let coordinator = SessionCoordinator(accessibility: fixture.service, initialState: .init(phase: .arming(sessionID)))
    await coordinator.triggerReleased(sessionID: sessionID)
    await coordinator.startCapture(sessionID: sessionID)
    #expect(await coordinator.currentSnapshot().phase == .ready)
    let stream = await coordinator.updates
    var updates = stream.makeAsyncIterator()
    #expect(await updates.next()?.message == "Hold the trigger while speaking.")
}

@MainActor
@Test
func staleCancellationCannotCancelAnotherSession() async {
    let fixture = DesktopFixture()
    let sessionID = DictationSessionID()
    let coordinator = SessionCoordinator(accessibility: fixture.service, initialState: .init(phase: .arming(sessionID)))
    await coordinator.cancel(expectedSessionID: DictationSessionID())
    #expect(await coordinator.currentSnapshot().phase == .arming(sessionID))
    await coordinator.cancel(expectedSessionID: sessionID)
    #expect(await coordinator.currentSnapshot().phase == .ready)
}

@MainActor
@Test
func recoveryConsumesTheMatchingResultOnlyOnce() async throws {
    let fixture = DesktopFixture(web: true)
    let result = LastResult(text: "Hello")
    let coordinator = SessionCoordinator(accessibility: fixture.service, initialState: .init(phase: .ready, lastResult: result))
    #expect(await coordinator.prepareRecoveryDestination(for: result.id) != nil)
    #expect(await coordinator.deliverLastResult(id: UUID()) == .failed(.destinationUnavailable))
    #expect(await coordinator.deliverLastResult(id: result.id) == .delivered)
    #expect(await coordinator.deliverLastResult(id: result.id) == .failed(.destinationUnavailable))
    #expect(await coordinator.lastResult() == nil)
    #expect(fixture.editor.string == "Hello")
}

@MainActor
@Test
func recoveryRejectsOverlappingDeliveryAndDismissal() async throws {
    let fixture = DesktopFixture(web: true)
    fixture.pasteDelay = .milliseconds(40)
    fixture.timing.confirmationTimeout = .seconds(1)
    let result = LastResult(text: "Hello")
    let coordinator = SessionCoordinator(accessibility: fixture.service, initialState: .init(phase: .ready, lastResult: result))
    #expect(await coordinator.prepareRecoveryDestination(for: result.id) != nil)
    let first = Task { await coordinator.deliverLastResult(id: result.id) }
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while fixture.pasteCount == 0, ContinuousClock.now < deadline { await Task.yield() }
    #expect(fixture.pasteCount == 1)
    #expect(await coordinator.deliverLastResult(id: result.id) == .failed(.destinationUnavailable))
    await coordinator.clearLastResult(id: result.id)
    #expect(await coordinator.lastResult()?.id == result.id)
    #expect(await first.value == .delivered)
    #expect(await coordinator.lastResult() == nil)
    #expect(fixture.editor.string == "Hello")
}

@MainActor
@Test
func unconfirmedRecoveryKeepsTheSameResultAndRequiresANewDestination() async throws {
    let fixture = DesktopFixture(web: true)
    fixture.pastedOverride = "World"
    let result = LastResult(text: "Hello")
    let coordinator = SessionCoordinator(accessibility: fixture.service, initialState: .init(phase: .ready, lastResult: result))
    #expect(await coordinator.prepareRecoveryDestination(for: result.id) != nil)
    #expect(await coordinator.deliverLastResult(id: result.id) == .unconfirmed)
    let preserved = try #require(await coordinator.lastResult())
    #expect(preserved.id == result.id)
    #expect(preserved.text == "Hello")
    #expect(preserved.deliveryUncertain)
    var updates = await coordinator.updates.makeAsyncIterator()
    let update = try #require(await updates.next())
    #expect(update.message == nil)
    let overlay = StatusOverlayController()
    overlay.update(update)
    #expect(overlay.window?.isVisible == false)
    #expect(await coordinator.deliverLastResult(id: result.id) == .failed(.destinationUnavailable))
    #expect(fixture.editor.string == "World")
    await coordinator.clearLastResult(id: UUID())
    #expect(await coordinator.lastResult()?.id == result.id)
}

@MainActor
@Test
func anAcceptedDirectRequestDoesNotAuthorizeAFallbackWrite() async throws {
    let fixture = DesktopFixture()
    fixture.directBehavior = .noOp
    let token = try #require(await fixture.service.captureCurrentDestination().token)
    _ = await fixture.service.deliver("Hello", to: token)
    #expect(fixture.directWriteCount == 1)
    #expect(fixture.pasteCount == 0)
    #expect(fixture.editor.string.isEmpty)
}
