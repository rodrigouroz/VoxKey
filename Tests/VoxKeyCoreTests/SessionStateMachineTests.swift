import Testing
@testable import VoxKeyCore

@Test func completeDeliveryReturnsToReady() throws {
    var machine = SessionStateMachine(phase: .ready)
    let sessionID = try machine.beginSession()
    try machine.beginCapture(sessionID: sessionID)
    try machine.beginFinalization(sessionID: sessionID)
    try machine.beginDelivery(sessionID: sessionID)
    try machine.finishDelivery(sessionID: sessionID)

    #expect(machine.phase == .ready)
    #expect(machine.lastResult == nil)
}

@Test func staleSessionCannotMutateSuccessor() throws {
    var machine = SessionStateMachine(phase: .ready)
    let original = try machine.beginSession()
    try machine.cancel(sessionID: original)
    let successor = try machine.beginSession()

    #expect(throws: SessionTransitionError.self) {
        try machine.beginCapture(sessionID: original)
    }
    #expect(machine.phase == .arming(successor))
}

@Test func failedDeliveryPreservesOnlyOneLastResult() throws {
    var machine = SessionStateMachine(phase: .ready)
    let first = try machine.beginSession()
    try machine.beginCapture(sessionID: first)
    try machine.beginFinalization(sessionID: first)
    try machine.beginDelivery(sessionID: first)
    try machine.preserveLastResult("first", sessionID: first)

    let second = try machine.beginSession()
    try machine.beginCapture(sessionID: second)
    try machine.beginFinalization(sessionID: second)
    try machine.beginDelivery(sessionID: second)
    try machine.preserveLastResult("second", sessionID: second)

    #expect(machine.lastResult?.text == "second")
}

@Test func busyMachineRejectsAnotherSession() throws {
    var machine = SessionStateMachine(phase: .ready)
    _ = try machine.beginSession()

    #expect(throws: SessionTransitionError.self) {
        try machine.beginSession()
    }
}

@Test(arguments: [CaptureMode.hold, .toggle])
func captureModeOwnsTriggerBehaviorForTheWholeSession(_ mode: CaptureMode) throws {
    var machine = SessionStateMachine(phase: .ready)
    let id = try machine.beginSession(captureMode: mode)
    #expect(machine.captureMode == mode)
    #expect(machine.triggerPressAction == .reject)
    #expect(machine.triggerReleaseAction(sessionID: id) == (mode == .hold ? .cancelArming : .ignore))
    try machine.beginCapture(sessionID: id)
    #expect(machine.triggerPressAction == (mode == .toggle ? .finish(id) : .reject))
    #expect(machine.triggerReleaseAction(sessionID: id) == (mode == .hold ? .finish : .ignore))
    #expect(machine.triggerReleaseAction(sessionID: DictationSessionID()) == .ignore)
    try machine.beginFinalization(sessionID: id)
    #expect(machine.triggerPressAction == .reject)
    #expect(machine.triggerReleaseAction(sessionID: id) == .ignore)
    try machine.beginDelivery(sessionID: id)
    #expect(machine.triggerPressAction == .reject)
    try machine.finishDelivery(sessionID: id)
    #expect(machine.triggerPressAction == .begin)
    _ = try machine.beginSession()
    #expect(machine.captureMode == .hold)
}
