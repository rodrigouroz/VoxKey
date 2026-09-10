import AppKit
import Testing
@testable import VoxKeyApp

@MainActor @Test(arguments: [false, true])
func setupRemainsInTheDockUntilItsWindowCloses(onboardingCompleted: Bool) throws {
    _ = NSApplication.shared
    let previousPolicy = NSApp.activationPolicy()
    defer { NSApp.setActivationPolicy(previousPolicy) }
    NSApp.setActivationPolicy(.accessory)
    let suite = "VoxKeyTests.LaunchOnboarding.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(onboardingCompleted, forKey: "VoxKeyOnboardingComplete")
    let app = AppController(defaults: defaults)
    defer { app.onboarding.close() }

    app.presentLaunchOnboardingIfNeeded(microphoneAuthorized: false, accessibilityTrusted: false)

    #expect(app.onboarding.window?.isVisible == true)
    #expect(NSApp.activationPolicy() == .regular)

    app.onboarding.close()

    #expect(app.onboarding.window?.isVisible == false)
    #expect(NSApp.activationPolicy() == .accessory)
}

@MainActor @Test(arguments: [false, true], [false, true])
func reopeningVoxKeyRestoresTheSetupWindow(hasVisibleWindows: Bool, onboardingCompleted: Bool) throws {
    _ = NSApplication.shared
    let previousPolicy = NSApp.activationPolicy()
    defer { NSApp.setActivationPolicy(previousPolicy) }
    let suite = "VoxKeyTests.LaunchOnboarding.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(onboardingCompleted, forKey: "VoxKeyOnboardingComplete")
    let app = AppController(defaults: defaults)
    defer { app.onboarding.close() }
    if hasVisibleWindows { app.onboarding.present() }
    let delegate: any NSApplicationDelegate = app

    let handled = delegate.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: hasVisibleWindows)

    #expect(handled == false)
    #expect(app.onboarding.window?.isVisible == true)
    #expect(NSApp.activationPolicy() == .regular)
}

@MainActor @Test
func aPreviouslyCompletedInstallOpensSetupWhenMicrophonePermissionIsMissing() throws {
    _ = NSApplication.shared
    let suite = "VoxKeyTests.LaunchOnboarding.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: "VoxKeyOnboardingComplete")
    defaults.set(true, forKey: "VoxKeyDefaultModelInstalled")
    let app = AppController(defaults: defaults)
    defer { app.onboarding.close() }

    app.presentLaunchOnboardingIfNeeded(microphoneAuthorized: false, accessibilityTrusted: true)

    #expect(app.onboarding.window?.isVisible == true)

    app.onboarding.close()
    app.presentLaunchOnboardingIfNeeded(microphoneAuthorized: false, accessibilityTrusted: true)
    #expect(app.onboarding.window?.isVisible == false)
}

@MainActor @Test
func setupOpensForNewInstallsAndMissingPrerequisitesButNotAReadyRestart() throws {
    _ = NSApplication.shared
    let suite = "VoxKeyTests.LaunchOnboarding.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let scenarios = [
        (completed: false, accessibility: true, modelInstalled: true, visible: true),
        (completed: true, accessibility: false, modelInstalled: true, visible: true),
        (completed: true, accessibility: true, modelInstalled: false, visible: true),
        (completed: true, accessibility: true, modelInstalled: true, visible: false),
    ]
    for scenario in scenarios {
        defaults.set(scenario.completed, forKey: "VoxKeyOnboardingComplete")
        defaults.set(scenario.modelInstalled, forKey: "VoxKeyDefaultModelInstalled")
        let app = AppController(defaults: defaults)
        defer { app.onboarding.close() }

        app.presentLaunchOnboardingIfNeeded(microphoneAuthorized: true, accessibilityTrusted: scenario.accessibility)

        #expect(app.onboarding.window?.isVisible == scenario.visible)
    }
}

@MainActor @Test
func aCachedModelMarkedMissingAfterLaunchOpensSetup() throws {
    _ = NSApplication.shared
    let suite = "VoxKeyTests.LaunchOnboarding.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: "VoxKeyOnboardingComplete")
    defaults.set(true, forKey: "VoxKeyDefaultModelInstalled")
    let app = AppController(defaults: defaults)
    defer { app.onboarding.close() }
    app.presentLaunchOnboardingIfNeeded(microphoneAuthorized: true, accessibilityTrusted: true)
    #expect(app.onboarding.window?.isVisible == false)

    // prepareModel clears this persisted flag when the cached model cannot be loaded.
    defaults.set(false, forKey: "VoxKeyDefaultModelInstalled")
    app.presentLaunchOnboardingIfNeeded(microphoneAuthorized: true, accessibilityTrusted: true)

    #expect(app.onboarding.window?.isVisible == true)
}
