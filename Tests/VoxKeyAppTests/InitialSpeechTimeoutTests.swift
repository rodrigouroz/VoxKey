import Foundation
import Synchronization
import Testing
@testable import VoxKeyApp
import VoxKeyCore

@MainActor
@Test(arguments: [Float?.none, Float(0), Float(0.004)])
func accidentalSilentCaptureStopsWithoutTranscribingOrChangingTheEditor(_ level: Float?) async throws {
    let desktop = DesktopFixture()
    let microphone = SyntheticAudioInput()
    let audio = AudioCaptureService(makeInput: { _ in microphone })
    let sessionID = DictationSessionID()
    let savedResult = LastResult(text: "Earlier saved dictation")
    let coordinator = SessionCoordinator(
        audioCapture: audio, accessibility: desktop.service,
        initialState: .init(phase: .arming(sessionID), lastResult: savedResult)
    )
    await coordinator.startCapture(sessionID: sessionID)
    if let level { microphone.emit(Array(repeating: level, count: 16_000)) }
    let deadline = ContinuousClock.now.advanced(by: .seconds(4))
    while await coordinator.currentSnapshot().phase.isBusy, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    let snapshot = await coordinator.currentSnapshot()
    let stream = await coordinator.updates
    var updates = stream.makeAsyncIterator()
    let completion = await updates.next()
    let inputClosed = !microphone.isRunning
    await coordinator.cancel(expectedSessionID: sessionID)
    #expect(snapshot.phase == .ready)
    #expect(inputClosed)
    #expect(completion?.message == InitialSilenceMessage.text(detectedAudio: (level ?? 0) > 0.001))
    #expect(snapshot.lastResult?.id == savedResult.id)
    #expect(desktop.editor.string.isEmpty)
    #expect(desktop.pasteboard.string(forType: .string) == "original clipboard")
    #expect(try await audio.stop().samples.isEmpty)
    await coordinator.triggerReleased(sessionID: sessionID)
    #expect(await coordinator.currentSnapshot().phase == .ready)
}

@MainActor
@Test(arguments: [16_000, 44_100, 48_000])
func speechBeforeTheDeadlineAllowsLaterPauses(_ sampleRate: Int) async throws {
    let desktop = DesktopFixture()
    let spoken = voicedSamples(seconds: 0.3, sampleRate: sampleRate)
    let samples = spoken + Array(repeating: Float.zero, count: sampleRate)
    let microphone = SyntheticAudioInput(sampleRate: Double(sampleRate), initialSamples: samples)
    let audio = AudioCaptureService(makeInput: { _ in microphone })
    let sessionID = DictationSessionID()
    let coordinator = SessionCoordinator(
        audioCapture: audio, accessibility: desktop.service,
        initialState: .init(phase: .arming(sessionID)),
        captureTiming: CaptureTiming(initialSpeechTimeout: .milliseconds(50))
    )
    await coordinator.startCapture(sessionID: sessionID)
    try await Task.sleep(for: .milliseconds(200))
    let snapshot = await coordinator.currentSnapshot()
    let stillRunning = microphone.isRunning
    let activityAfterStreamingDrain = await audio.speechStartStatus()
    await coordinator.cancel(expectedSessionID: sessionID)
    #expect(snapshot.phase == .capturing(sessionID))
    #expect(stillRunning)
    #expect(activityAfterStreamingDrain == .speech)
    #expect(try await audio.stop().samples.isEmpty)
}

@MainActor
@Test(arguments: [false, true])
func anOnsetNearTheDeadlineGetsOnlyOneGracePeriod(_ continuesSpeaking: Bool) async throws {
    let desktop = DesktopFixture()
    let microphone = SyntheticAudioInput(initialSamples: voicedSamples(seconds: 0.05))
    let audio = AudioCaptureService(makeInput: { _ in microphone })
    let sessionID = DictationSessionID()
    let coordinator = SessionCoordinator(
        audioCapture: audio, accessibility: desktop.service,
        initialState: .init(phase: .arming(sessionID)),
        captureTiming: CaptureTiming(initialSpeechTimeout: .milliseconds(100), speechStartGrace: .seconds(1))
    )
    await coordinator.startCapture(sessionID: sessionID)
    try await Task.sleep(for: .milliseconds(250))
    let duringGrace = await coordinator.currentSnapshot()
    if continuesSpeaking { microphone.emit(voicedSamples(seconds: 0.3)) }
    try await Task.sleep(for: .seconds(1))
    let afterGrace = await coordinator.currentSnapshot()
    let stillRunning = microphone.isRunning
    await coordinator.cancel(expectedSessionID: sessionID)
    #expect(duringGrace.phase == .capturing(sessionID))
    #expect(afterGrace.phase == (continuesSpeaking ? .capturing(sessionID) : .ready))
    #expect(stillRunning == continuesSpeaking)
}

@Test
func aNewCaptureDoesNotInheritSpeechFromThePreviousOne() async throws {
    let microphone = SyntheticAudioInput()
    let audio = AudioCaptureService(makeInput: { _ in microphone })
    try await audio.start()
    microphone.emit(voicedSamples(seconds: 0.3))
    let firstStatus = await audio.speechStartStatus()
    await audio.cancel()
    try await audio.start()
    let secondStatus = await audio.speechStartStatus()
    await audio.cancel()
    #expect(firstStatus == .speech)
    #expect(secondStatus == .silent)
    #expect(!microphone.isRunning)
}

private func voicedSamples(seconds: Double, sampleRate: Int = 16_000) -> [Float] {
    (0..<Int(Double(sampleRate) * seconds)).map {
        Float(sin(2 * Double.pi * 220 * Double($0) / Double(sampleRate))) * 0.08
    }
}

/// Substitutes only hardware callbacks; capture, buffering, VAD and coordination are real.
final class SyntheticAudioInput: AudioInputDevice, Sendable {
    private struct State {
        var available = true
        var write: (@Sendable (UnsafePointer<Float>, Int) -> Void)?
    }
    private let state = Mutex(State())
    let sampleRate: Double
    private let initialSamples: [Float]

    init(sampleRate: Double = 16_000, initialSamples: [Float] = []) {
        self.sampleRate = sampleRate
        self.initialSamples = initialSamples
    }
    var isAvailable: Bool { state.withLock { $0.available } }
    func disconnect() { state.withLock { $0.available = false; $0.write = nil } }
    var isRunning: Bool { state.withLock { $0.write != nil } }
    func start(write: @escaping @Sendable (UnsafePointer<Float>, Int) -> Void) throws {
        state.withLock { $0.write = write }
        emit(initialSamples)
    }
    func stop() { state.withLock { $0.write = nil } }
    func emit(_ samples: [Float]) {
        let write = state.withLock { $0.write }
        samples.withUnsafeBufferPointer { buffer in
            guard let pointer = buffer.baseAddress else { return }
            write?(pointer, buffer.count)
        }
    }
}

@Test
func audioRingDrainFeedsTheMeterAndANewCaptureResetsIt() async throws {
    let microphone = SyntheticAudioInput()
    let audio = AudioCaptureService(makeInput: { _ in microphone })
    try await audio.start()
    microphone.emit(Array(repeating: Float(0.1), count: 1_600))
    _ = try await audio.takePendingAudio()
    #expect(await audio.inputLevel() > 0)
    #expect(await audio.detectedAudio())
    await audio.cancel()
    try await audio.start()
    #expect(await audio.inputLevel() == 0)
    #expect(await audio.detectedAudio() == false)
    await audio.cancel()
}

@MainActor @Test
func capturingSnapshotsExposeLevelsAtABoundedRateAndClearThemOnCancellation() async throws {
    let desktop = DesktopFixture()
    let microphone = SyntheticAudioInput()
    let id = DictationSessionID()
    let coordinator = SessionCoordinator(audioCapture: AudioCaptureService(makeInput: { _ in microphone }),
        accessibility: desktop.service, initialState: .init(phase: .arming(id)))
    let stream = await coordinator.updates
    let observer = Task { () -> [SessionSnapshot] in
        var captures: [SessionSnapshot] = []
        for await snapshot in stream {
            if case .capturing = snapshot.phase { captures.append(snapshot) }
            if snapshot.message == "Cancelled" { return captures }
        }
        return captures
    }
    await coordinator.startCapture(sessionID: id)
    microphone.emit(Array(repeating: Float(0.1), count: 1_600))
    try await Task.sleep(for: .milliseconds(230))
    await coordinator.cancel(expectedSessionID: id)
    let captures = await observer.value
    #expect(captures.count >= 2)
    for (before, after) in zip(captures, captures.dropFirst()) {
        #expect(after.elapsedSeconds - before.elapsedSeconds >= 0.045)
    }
    #expect(captures.contains { ($0.inputLevel ?? 0) > 0 })
    #expect(await coordinator.currentSnapshot().inputLevel == nil)
}
