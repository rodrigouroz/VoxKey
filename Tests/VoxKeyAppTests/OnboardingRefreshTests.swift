import AppKit
import Testing
@testable import VoxKeyApp

@MainActor @Test
func hiddenOnboardingSkipsRenderingAndOpeningRefreshesIt() throws {
    _ = NSApplication.shared
    let previousPolicy = NSApp.activationPolicy()
    defer { NSApp.setActivationPolicy(previousPolicy) }
    let app = AppController()
    defer { app.onboarding.close() }
    let initial = "Initial rendered status"
    app.updateOnboarding(message: initial, force: true)
    let root = try #require(app.onboarding.window?.contentView)
    func labels(_ view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(labels)
    }
    let message = try #require(labels(root).first { $0.stringValue == initial })
    app.updateOnboarding(message: "An update while hidden")
    #expect(message.stringValue == initial)
    _ = app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
    #expect(app.onboarding.window?.isVisible == true)
    #expect(message.stringValue != initial)
    app.updateOnboarding(message: "Visible update")
    #expect(message.stringValue == "Visible update")
    app.onboarding.close()
    app.updateOnboarding(message: "Hidden again")
    #expect(message.stringValue == "Visible update")
}
