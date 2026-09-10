import AVFoundation
import Foundation
import VoxKeyCore
import Testing
@testable import VoxKeyApp

@MainActor
@Test
func captureCueWaitsForPlaybackCompletion() async throws {
    let output = ControlledCueOutput()
    let cues = CaptureCuePlayer(output: output)
    var finished = false
    let playback = Task { await cues.playStart(); finished = true }
    try await output.waitForPlayback()
    // A sound that takes longer than the former 140 ms must still block microphone opening.
    try await Task.sleep(for: .milliseconds(200))
    #expect(!finished)
    output.complete()
    await playback.value
    #expect(finished)
}

@MainActor
final class ControlledCueOutput: CaptureCueOutput {
    var activeCue: CaptureCue?
    var acceptsPlayback = true
    var completion: (@MainActor @Sendable () -> Void)?

    func play(_ cue: CaptureCue, completion: @escaping @MainActor @Sendable () -> Void) -> Bool {
        guard acceptsPlayback else { return false }
        activeCue = cue
        self.completion = completion
        return true
    }

    func waitForPlayback() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while activeCue == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(activeCue != nil, "Expected sound playback before the deadline")
    }

    func complete() {
        let callback = completion
        stop()
        callback?()
    }

    func stop() {
        activeCue = nil
        completion = nil
    }
}

@MainActor
@Test(arguments: CaptureCue.allCases)
func captureCueAssetsAreShortPlayableAudio(_ cue: CaptureCue) throws {
    let player = try AVAudioPlayer(contentsOf: #require(cue.url))
    #expect(player.duration > 0.04)
    #expect(player.duration < 0.2)
    #expect(player.numberOfChannels == 1)
    #expect(try Data(contentsOf: #require(CaptureCue.start.url)) != Data(contentsOf: #require(CaptureCue.stop.url)))
}

@MainActor
@Test
func disabledCaptureCuesProduceNoPlayback() async {
    let output = ControlledCueOutput()
    let cues = CaptureCuePlayer(output: output)
    cues.enabled = false
    await cues.playStart()
    await cues.playStop()
    await cues.playRejection()
    #expect(output.activeCue == nil)
}

@MainActor
@Test(arguments: [false, true])
func unavailableOrStalledCueOutputDoesNotBlockCapture(_ stalled: Bool) async {
    let output = ControlledCueOutput()
    output.acceptsPlayback = stalled
    let cues = CaptureCuePlayer(output: output, timeout: .milliseconds(20))
    let microphone = SyntheticAudioInput()
    let desktop = DesktopFixture()
    let id = DictationSessionID()
    let coordinator = SessionCoordinator(
        audioCapture: AudioCaptureService(makeInput: { _ in microphone }),
        accessibility: desktop.service, initialState: .init(phase: .arming(id)), cuePlayer: cues
    )
    await coordinator.startCapture(sessionID: id)
    #expect(microphone.isRunning)
    #expect(output.activeCue == nil)
    await coordinator.cancel(expectedSessionID: id)
    #expect(!microphone.isRunning)
}

@MainActor
@Test(arguments: [false, true])
func releaseOrEscapeDuringTheStartCueNeverOpensTheMicrophone(_ escape: Bool) async throws {
    let output = ControlledCueOutput()
    let cues = CaptureCuePlayer(output: output)
    let microphone = SyntheticAudioInput()
    let desktop = DesktopFixture()
    let id = DictationSessionID()
    let previous = LastResult(text: "Earlier dictation")
    let coordinator = SessionCoordinator(
        audioCapture: AudioCaptureService(makeInput: { _ in microphone }),
        accessibility: desktop.service, initialState: .init(phase: .arming(id), lastResult: previous), cuePlayer: cues
    )
    let starting = Task { await coordinator.startCapture(sessionID: id) }
    try await output.waitForPlayback()
    #expect(output.activeCue == .start)
    #expect(!microphone.isRunning)
    if escape { await coordinator.cancel(expectedSessionID: id) }
    else { await coordinator.triggerReleased(sessionID: id) }
    await starting.value
    #expect(output.activeCue == nil)
    #expect(!microphone.isRunning)
    #expect(await coordinator.currentSnapshot().phase == .ready)
    #expect(await coordinator.lastResult()?.id == previous.id)
}

enum CaptureEnd: CaseIterable { case release, escape, initialSilence }

@MainActor
@Test(arguments: CaptureEnd.allCases)
func everyCaptureEndClosesInputBeforeSoundWithoutASnapshotConsumer(_ ending: CaptureEnd) async throws {
    let output = ControlledCueOutput()
    let cues = CaptureCuePlayer(output: output)
    let microphone = SyntheticAudioInput()
    let desktop = DesktopFixture()
    let id = DictationSessionID()
    let coordinator = SessionCoordinator(
        audioCapture: AudioCaptureService(makeInput: { _ in microphone }), accessibility: desktop.service,
        initialState: .init(phase: .arming(id)),
        captureTiming: CaptureTiming(initialSpeechTimeout: ending == .initialSilence ? .milliseconds(50) : .seconds(3)),
        cuePlayer: cues
    )
    let starting = Task { await coordinator.startCapture(sessionID: id) }
    try await output.waitForPlayback()
    #expect(!microphone.isRunning)
    output.complete()
    await starting.value
    #expect(microphone.isRunning)
    let stopping = Task {
        switch ending {
        case .release: await coordinator.triggerReleased(sessionID: id)
        case .escape: await coordinator.cancel(expectedSessionID: id)
        case .initialSilence: break // Exercise the real scheduled timeout.
        }
    }
    try await output.waitForPlayback()
    #expect(output.activeCue == .stop)
    #expect(!microphone.isRunning)
    #expect(await coordinator.currentSnapshot().phase.isBusy)
    output.complete()
    await stopping.value
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while await coordinator.currentSnapshot().phase.isBusy, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(await coordinator.currentSnapshot().phase == .ready)
    #expect(output.activeCue == nil)
    #expect(desktop.editor.string.isEmpty)
    // Release exercises real model-unavailable failure, after its single stop cue.
}

@MainActor
@Test
func silentModeStillCapturesAndRejectsOverlappingTriggersWithoutSound() async {
    let output = ControlledCueOutput()
    let cues = CaptureCuePlayer(output: output)
    cues.enabled = false
    let microphone = SyntheticAudioInput()
    let desktop = DesktopFixture()
    let id = DictationSessionID()
    let coordinator = SessionCoordinator(
        audioCapture: AudioCaptureService(makeInput: { _ in microphone }),
        accessibility: desktop.service, initialState: .init(phase: .arming(id)), cuePlayer: cues
    )
    await coordinator.startCapture(sessionID: id)
    #expect(microphone.isRunning)
    #expect(await coordinator.currentSnapshot().phase == .capturing(id))
    cues.enabled = true
    #expect(await coordinator.triggerPressed() == nil)
    #expect(output.activeCue == nil)
    #expect(microphone.isRunning)
    cues.enabled = false
    await coordinator.cancel(expectedSessionID: id)
    #expect(!microphone.isRunning)
    #expect(output.activeCue == nil)
}

@MainActor
@Test
func disablingOrCancellingPlaybackStopsOutputAndIgnoresLateCallbacks() async throws {
    let output = ControlledCueOutput()
    let cues = CaptureCuePlayer(output: output)
    let first = Task { await cues.playStart() }
    try await output.waitForPlayback()
    let staleCompletion = output.completion
    cues.enabled = false
    await first.value
    #expect(output.activeCue == nil)
    cues.enabled = true
    let successor = Task { await cues.playStart() }
    try await output.waitForPlayback()
    staleCompletion?()
    #expect(output.activeCue == .start)
    successor.cancel()
    await successor.value
    #expect(output.activeCue == nil)
}

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["VOXKEY_VALIDATE_CUE_AUDIO"] == "1"))
func hardwareCaptureCueCompletion() async throws {
    // Opt-in because this test uses the actual selected output and plays audible tones.
    for cue in CaptureCue.allCases {
        let output = SystemCaptureCueOutput()
        var completed = false
        let accepted = output.play(cue) { completed = true }
        try #require(accepted, "The current output must accept the bundled cue")
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !completed, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        output.stop()
        #expect(completed, "Expected a real AVAudioPlayer completion callback")
    }
}

@Test
func captureCueResourcesRelocateWithTheAppAndMissingAssetsFailSilently() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let appURL = root.appendingPathComponent("VoxKey.app")
    let contents = appURL.appendingPathComponent("Contents")
    let resources = contents.appendingPathComponent("Resources/VoxKey_VoxKeyApp.bundle")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let info = try PropertyListSerialization.data(fromPropertyList: [
        "CFBundleIdentifier": "com.voxkey.test.cues", "CFBundlePackageType": "APPL"
    ], format: .xml, options: 0)
    try info.write(to: contents.appendingPathComponent("Info.plist"))
    let app = try #require(Bundle(url: appURL))
    #expect(CaptureCue.start.url(in: app) == nil)
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    for cue in CaptureCue.allCases {
        let target = resources.appendingPathComponent("\(cue.rawValue).wav")
        try FileManager.default.copyItem(at: #require(cue.url), to: target)
    }
    // Bundle caches directory contents; finish constructing the app before loading assets.
    for cue in CaptureCue.allCases {
        let target = resources.appendingPathComponent("\(cue.rawValue).wav")
        let relocated = try #require(cue.url(in: app))
        #expect(relocated.standardizedFileURL == target.standardizedFileURL)
        #expect(try AVAudioPlayer(contentsOf: relocated).duration > 0)
    }
}
