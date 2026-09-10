import AppKit
import Testing
import VoxKeyCore
@testable import VoxKeyApp

@MainActor @Test
func anUpdateWaitsForDictationAndRecoveryBeforeRestartingOnce() {
    let gate = UpdateInstallGate()
    let session = DictationSessionID()
    gate.update(.init(phase: .capturing(session), lastResult: nil))
    var restarted = false
    #expect(!gate.canCheckForUpdates)
    #expect(gate.postponeIfNeeded { restarted = true })
    gate.update(.init(phase: .finalizing(session), lastResult: nil))
    #expect(!restarted)
    gate.update(.init(phase: .ready, lastResult: .init(text: "Synthetic result", failure: .destinationChanged)))
    #expect(gate.canCheckForUpdates)
    #expect(!restarted)
    #expect(gate.isWaiting)
    gate.update(.init(phase: .ready, lastResult: nil))
    #expect(restarted)
    #expect(!gate.isWaiting)
    restarted = false
    gate.update(.init(phase: .ready, lastResult: nil))
    #expect(!restarted)
}

@MainActor @Test
func anUpdatePreservesUncertainAndUndirectedDictation() {
    let gate = UpdateInstallGate()
    gate.update(.init(phase: .ready, lastResult: .init(text: "Synthetic result", deliveryUncertain: true)))
    var restarted = false
    #expect(gate.postponeIfNeeded { restarted = true })
    gate.update(.init(phase: .ready, lastResult: .init(text: "Another result"), attention: .dictationReady))
    #expect(!restarted)
    gate.update(.init(phase: .ready, lastResult: nil))
    #expect(restarted)
}

@MainActor @Test
func aConfirmedDeliveryDoesNotPreventInstallingAnUpdate() {
    let gate = UpdateInstallGate()
    gate.update(.init(phase: .ready, lastResult: .init(text: "Already delivered")))
    #expect(!gate.postponeIfNeeded { Issue.record("Sparkle owns immediate installation") })
    #expect(!gate.isWaiting)
}

@MainActor @Test
func menuValidationKeepsUpdatesDisabledOutsideDistributionBuilds() {
    let updates = UpdateController()
    let menu = NSMenu()
    updates.addMenuItems(to: menu)
    menu.update()
    let actions = menu.items.filter { $0.action != nil }
    #expect(actions.count == 2)
    #expect(actions.allSatisfy { !$0.isEnabled })
}
