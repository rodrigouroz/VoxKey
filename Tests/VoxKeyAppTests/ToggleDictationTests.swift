import AppKit
import Testing
@testable import VoxKeyApp
import VoxKeyCore

@MainActor @Test
func toggleCaptureIgnoresReleaseAndSecondPressClosesTheMicrophone() async throws {
    let desktop = DesktopFixture()
    let microphone = SyntheticAudioInput()
    let audio = AudioCaptureService(makeInput: { _ in microphone })
    var machine = SessionStateMachine(phase: .ready)
    let id = try machine.beginSession(captureMode: .toggle)
    let coordinator = SessionCoordinator(audioCapture: audio, accessibility: desktop.service, initialState: machine)
    // Releasing during arming must not select the hold-mode quick-release path.
    await coordinator.triggerReleased(sessionID: id)
    await coordinator.startCapture(sessionID: id)
    #expect(microphone.isRunning)
    await coordinator.triggerReleased(sessionID: id)
    #expect(await coordinator.currentSnapshot().phase == .capturing(id))
    #expect(await coordinator.currentSnapshot().captureMode == .toggle)
    _ = await coordinator.triggerPressed(captureMode: .hold)
    #expect(!microphone.isRunning)
    #expect(await coordinator.currentSnapshot().phase == .ready)
    #expect(desktop.editor.string.isEmpty)
}

@MainActor @Test(arguments: [false, true])
func toggleCaptureStillStopsOnEscapeOrInitialSilence(_ escape: Bool) async throws {
    let desktop = DesktopFixture()
    let microphone = SyntheticAudioInput()
    var machine = SessionStateMachine(phase: .ready)
    let id = try machine.beginSession(captureMode: .toggle)
    let coordinator = SessionCoordinator(audioCapture: AudioCaptureService(makeInput: { _ in microphone }),
        accessibility: desktop.service, initialState: machine,
        captureTiming: CaptureTiming(initialSpeechTimeout: .milliseconds(50)))
    await coordinator.startCapture(sessionID: id)
    if escape { await coordinator.cancel(expectedSessionID: id) }
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while await coordinator.currentSnapshot().phase.isBusy, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await coordinator.currentSnapshot().phase == .ready)
    #expect(!microphone.isRunning)
    #expect(desktop.editor.string.isEmpty)
}

@MainActor @Test
func settingsShowTheConfiguredToggleGesture() throws {
    _ = NSApplication.shared
    let settings = SettingsWindowController()
    settings.updateTrigger(.rightCommand)
    settings.updateCaptureMode(.toggle)
    #expect(settings.toggleCheckbox.state == .on)
    // The readiness check in setup explains the same gesture.
    let setup = OnboardingWindowController()
    setup.updateTrigger(.rightCommand)
    setup.updateCaptureMode(.toggle)
    #expect(setup.testTextView.accessibilityHelp()?.contains("Press Right Command") == true)
    var selected: CaptureMode?
    settings.onCaptureModeChanged = { selected = $0 }
    settings.toggleCheckbox.performClick(nil)
    #expect(selected == .hold)
}
