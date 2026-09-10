import AppKit
import Testing
@testable import VoxKeyApp

@MainActor
@Test
func foregroundPresentationWaitsForActualApplicationActivation() {
    var isActive = false
    var currentProcessIdentifier: pid_t? = 42
    var requestedFrom: pid_t?
    var madeKey = 0
    let coordinator = ApplicationActivationCoordinator(
        ownProcessIdentifier: 7,
        isActive: { isActive },
        currentProcessIdentifier: { currentProcessIdentifier },
        requestActivation: { requestedFrom = $0 },
        restoreActivation: { _ in }
    )

    coordinator.present {
        madeKey += 1
    }

    #expect(requestedFrom == 42)
    #expect(madeKey == 0)

    isActive = true
    currentProcessIdentifier = 7
    coordinator.applicationDidBecomeActive()

    #expect(madeKey == 1)
}

@MainActor
@Test
func foregroundPresentationRestoresTheOriginalExternalApplication() {
    var currentProcessIdentifier: pid_t? = 42
    var restoredProcessIdentifier: pid_t?
    let coordinator = ApplicationActivationCoordinator(
        ownProcessIdentifier: 7,
        isActive: { true },
        currentProcessIdentifier: { currentProcessIdentifier },
        requestActivation: { _ in },
        restoreActivation: { restoredProcessIdentifier = $0 }
    )

    coordinator.present {}
    currentProcessIdentifier = 7
    coordinator.present {}
    coordinator.restorePreviousApplication()

    #expect(restoredProcessIdentifier == 42)
}

@MainActor
@Test
func foregroundPresentationDoesNotStealFocusBackAfterAnotherAppTakesOver() {
    var currentProcessIdentifier: pid_t? = 42
    var restoredProcessIdentifier: pid_t?
    let coordinator = ApplicationActivationCoordinator(
        ownProcessIdentifier: 7,
        isActive: { false },
        currentProcessIdentifier: { currentProcessIdentifier },
        requestActivation: { _ in },
        restoreActivation: { restoredProcessIdentifier = $0 }
    )

    coordinator.present {}
    currentProcessIdentifier = 99
    coordinator.restorePreviousApplication()

    #expect(restoredProcessIdentifier == nil)
}
