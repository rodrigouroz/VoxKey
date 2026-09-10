import CoreAudio
import AppKit
import Synchronization
import Testing
@testable import VoxKeyApp
import VoxKeyCore

@Test(arguments: [false, true])
func captureFactoryReceivesThePinnedDeviceOrFallsBackWhenItDisappears(_ disappears: Bool) async throws {
    let microphone = SyntheticAudioInput()
    let calls = Mutex<[AudioDeviceID?]>([])
    let service = AudioCaptureService { id in
        calls.withLock { $0.append(id) }
        if disappears, id != nil { throw AudioCaptureError.inputUnavailable }
        return microphone
    }
    let catalog = AudioInputCatalog(devices: [.init(id: 42, uid: "stable-uid", name: "Synthetic input")], defaultID: 10)
    try await service.start(selection: catalog.selection(for: "stable-uid"))
    #expect(calls.withLock { $0 } == (disappears ? [42, nil] : [42]))
    #expect(await service.usedDefaultFallback == disappears)
    #expect(microphone.isRunning)
    await service.cancel()
    #expect(!microphone.isRunning)
}

@Test
func anAbsentPinFallsBackAndReconnectionResolvesItsUIDToANewIdentifier() async throws {
    let microphone = SyntheticAudioInput()
    let calls = Mutex<[AudioDeviceID?]>([])
    let service = AudioCaptureService { id in calls.withLock { $0.append(id) }; return microphone }
    let absent = AudioInputCatalog()
    try await service.start(selection: absent.selection(for: "stable-uid"))
    #expect(await service.usedDefaultFallback)
    await service.cancel()
    let connected = AudioInputCatalog(devices: [.init(id: 99, uid: "stable-uid", name: "Synthetic input")])
    try await service.start(selection: connected.selection(for: "stable-uid"))
    #expect(!((await service.usedDefaultFallback)))
    #expect(calls.withLock { $0 } == [nil, 99])
    await service.cancel()
}

@MainActor @Test
func microphoneSettingsPreserveDuplicateNamesAndUnavailablePins() throws {
    _ = NSApplication.shared
    let controller = OnboardingWindowController()
    let devices: [AudioInputDescriptor] = [.init(id: 1, uid: "one", name: "Same name"), .init(id: 2, uid: "two", name: "Same name")]
    controller.updateMicrophones(.init(devices: devices, defaultID: 1), pinnedUID: "two")
    #expect(controller.microphonePopup.numberOfItems == 3)
    #expect(controller.microphonePopup.indexOfSelectedItem == 2)
    #expect(controller.microphonePopup.itemTitle(at: 0) == "System default (Same name)")
    controller.updateMicrophones(.init(), pinnedUID: "two")
    #expect(controller.microphonePopup.titleOfSelectedItem == "Pinned microphone (unavailable)")
}

@MainActor @Test(arguments: [CaptureMode.hold, .toggle])
func deviceLossEndsCaptureWithoutOpeningAnotherInput(_ mode: CaptureMode) async throws {
    let desktop = DesktopFixture()
    let microphone = SyntheticAudioInput()
    let calls = Mutex(0)
    let audio = AudioCaptureService { _ in calls.withLock { $0 += 1 }; return microphone }
    var machine = SessionStateMachine(phase: .ready)
    let id = try machine.beginSession(captureMode: mode)
    let coordinator = SessionCoordinator(audioCapture: audio, accessibility: desktop.service, initialState: machine)
    await coordinator.startCapture(sessionID: id)
    microphone.disconnect()
    await coordinator.enforceCaptureSafety()
    #expect(await coordinator.currentSnapshot().phase.isBusy == false)
    #expect(!microphone.isRunning)
    #expect(calls.withLock { $0 } == 1)
    #expect(desktop.editor.string.isEmpty)
}
