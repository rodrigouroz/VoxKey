import AppKit
import Testing
@testable import VoxKeyApp
import VoxKeyCore

@MainActor
@Test(arguments: [nil, .delivered, .unconfirmed, .failed(.destinationChanged)] as [DeliveryOutcome?])
func recoveryMenuAppearsOnlyForAnUnresolvedDictation(outcome: DeliveryOutcome?) throws {
    _ = NSApplication.shared
    let app = AppController()
    let menu = NSMenu()
    let recoveryAction = NSSelectorFromString("openSafetyNet")
    var machine = SessionStateMachine(phase: .ready)
    app.rebuildMenu(menu, snapshot: machine.snapshot())
    #expect(menu.items.allSatisfy { $0.action != recoveryAction })

    let id = try machine.beginSession()
    try machine.beginCapture(sessionID: id)
    try machine.beginFinalization(sessionID: id)
    try machine.beginDelivery(sessionID: id, text: "Test dictation")
    app.rebuildMenu(menu, snapshot: machine.snapshot())
    #expect(menu.items.allSatisfy { $0.action != recoveryAction })

    if let outcome {
        try machine.finishDelivery(sessionID: id, outcome: outcome)
    } else {
        try machine.preserveLastResult("Test dictation", sessionID: id)
    }
    app.rebuildMenu(menu, snapshot: machine.snapshot())
    let recovery = menu.items.first { $0.action == recoveryAction }
    if outcome == .delivered {
        #expect(recovery == nil)
    } else {
        let item = try #require(recovery)
        #expect(item.title == "Recover Dictation…")
        #expect(item.isEnabled)
        #expect(item.target === app)
    }

    machine.clearLastResult()
    app.rebuildMenu(menu, snapshot: machine.snapshot())
    #expect(menu.items.allSatisfy { $0.action != recoveryAction })
}

@MainActor @Test
func theSettingsFieldAcceptsThePasteShortcutUsedByDictation() throws {
    _ = NSApplication.shared
    let previousMenu = NSApp.mainMenu
    let previousResponder = NSApp.nextResponder
    defer {
        NSApp.mainMenu = previousMenu
        NSApp.nextResponder = previousResponder
    }
    NSApp.mainMenu = nil
    let app = AppController()
    app.configureApplicationMenu()
    let field = app.onboarding.testTextView
    field.string = "Before old after"
    field.setSelectedRange(NSRange(location: 7, length: 3))
    // A SwiftPM test runner has no active application window. Put the real
    // settings editor in its responder chain without taking desktop focus.
    NSApp.nextResponder = field
    try #require(NSApp.target(forAction: #selector(NSText.paste(_:))) as AnyObject? === field)
    let lease = try #require(PasteboardLease.begin(text: "new words", pasteboard: .general))
    defer { _ = lease.restoreIfOwned() }
    let event = try #require(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
        windowNumber: 0, context: nil, characters: "v",
        charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9
    ))

    #expect(NSApp.mainMenu?.performKeyEquivalent(with: event) == true)
    #expect(field.string == "Before new words after")
    #expect(field.selectedRange() == NSRange(location: 16, length: 0))
}
