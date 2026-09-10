import AppKit
import Testing
@testable import VoxKeyApp
import VoxKeyCore

@MainActor
@Test(arguments: 0..<32)
func correctInsertionDoesNotBecomeAFailureWhenAXObservationsVary(variant: Int) async throws {
    let fixture = DesktopFixture(web: variant.isMultiple(of: 2))
    if variant & 2 != 0 { fixture.frozenSelectedRange = NSRange(location: 0, length: 0) }
    if variant & 4 != 0 { fixture.frozenCharacterCount = 0 }
    fixture.selectionUnavailableAfterWrite = variant & 8 != 0
    fixture.textUnavailableAfterWrite = variant & 16 != 0
    let transcript = "Hello 👩🏽‍💻 " + String(repeating: "test é ", count: 45)
    let expected = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    let token = try #require(await fixture.service.captureCurrentDestination().token)
    let outcome = await fixture.service.deliver(transcript, to: token)
    await fixture.service.waitForPendingPaste()
    // Ground truth is NSTextView storage, independent of all overridden AX reads.
    #expect(fixture.editor.string == expected)
    #expect(outcome == .delivered || outcome == .unconfirmed)
    #expect(fixture.directWriteCount + fixture.pasteCount == 1)
    #expect(fixture.pasteboard.string(forType: .string) == "original clipboard")
}

@MainActor
@Test
func delayedAcceptedDirectWriteStillAppliesExactlyOnce() async throws {
    let fixture = DesktopFixture()
    fixture.directBehavior = .delayedWrite
    let token = try #require(await fixture.service.captureCurrentDestination().token)
    #expect(await fixture.service.deliver("Hello", to: token) == .unconfirmed)
    await fixture.pendingDirectWrite?.value
    #expect(fixture.editor.string == "Hello")
    #expect(fixture.directWriteCount == 1)
    #expect(fixture.pasteCount == 0)
}

@MainActor
@Test(arguments: [false, true])
func backgroundClipboardSettlementPreservesTheEditorAndNewUserCopies(copyAgain: Bool) async throws {
    let fixture = DesktopFixture(web: true)
    fixture.pasteDelay = .milliseconds(60)
    fixture.timing.foregroundConfirmationTimeout = .milliseconds(5)
    fixture.timing.confirmationTimeout = .seconds(1)
    let token = try #require(await fixture.service.captureCurrentDestination().token)
    let outcome = await fixture.service.deliver("Hello", to: token)
    #expect(outcome == .unconfirmed || outcome == .delivered)
    if copyAgain {
        // External clipboard ownership may change after the target consumes it.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while fixture.editor.string.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
        fixture.pasteboard.clearContents()
        fixture.pasteboard.setString("new user copy", forType: .string)
    }
    await fixture.service.waitForPendingPaste()
    #expect(fixture.editor.string == "Hello")
    #expect(fixture.pasteCount == 1)
    #expect(fixture.pasteboard.string(forType: .string) == (copyAgain ? "new user copy" : "original clipboard"))
}

@MainActor
@Test
func shutdownSettlesPendingClipboardAndRejectsNewWrites() async throws {
    let fixture = DesktopFixture(web: true)
    fixture.pasteDelay = .milliseconds(60)
    fixture.timing.foregroundConfirmationTimeout = .milliseconds(5)
    fixture.timing.confirmationTimeout = .seconds(1)
    let token = try #require(await fixture.service.captureCurrentDestination().token)
    _ = await fixture.service.deliver("Hello", to: token)
    await fixture.service.shutDown()
    #expect(fixture.editor.string == "Hello")
    #expect(fixture.pasteboard.string(forType: .string) == "original clipboard")
    #expect(await fixture.service.captureCurrentDestination().token == nil)
}

@Test(arguments: [DeliveryOutcome.delivered, .unconfirmed, .failed(.destinationChanged)])
func transcriptIsSavedBeforeDeliveryAndOnlyKnownFailuresNeedAttention(outcome: DeliveryOutcome) throws {
    var state = SessionStateMachine(phase: .ready)
    let id = try state.beginSession()
    try state.beginCapture(sessionID: id)
    try state.beginFinalization(sessionID: id)
    try state.beginDelivery(sessionID: id, text: "Hello")
    let saved = try #require(state.lastResult)
    #expect(saved.text == "Hello")
    try state.finishDelivery(sessionID: id, outcome: outcome)
    #expect(state.phase == .ready)
    if outcome == .delivered {
        #expect(state.lastResult == nil)
        return
    }
    #expect(state.lastResult?.id == saved.id)
    if case let .failed(reason) = outcome {
        #expect(state.lastResult?.failure == reason)
        #expect(state.lastResult?.deliveryUncertain == false)
    } else {
        #expect(state.lastResult?.failure == nil)
        #expect(state.lastResult?.deliveryUncertain == true)
    }
}
