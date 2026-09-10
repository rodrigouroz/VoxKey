import AppKit
import Testing
@testable import VoxKeyApp
import VoxKeyCore

@MainActor
@Test
func dictationWithoutDestinationUsesNeutralPresentation() throws {
    _ = NSApplication.shared
    let controller = SafetyNetWindowController(result: LastResult(text: "My completed dictation"), destination: nil)
    let root = try #require(controller.window?.contentView)
    #expect(root.label(containing: "Your dictation is ready.") != nil)
    #expect(root.label(containing: "Your words are still here.") == nil)
    #expect(root.label(containing: "Copy your text, or focus an input and choose Recover Dictation… from the VoxKey menu to insert it.") != nil)
    #expect(root.button(titled: "Deliver")?.isEnabled == false)
    #expect(root.button(titled: "Deliver")?.isHidden == true)
    #expect(root.button(titled: "Copy (⌘C)")?.isEnabled == true)
    #expect(root.button(titled: "I checked the input; insert this text again")?.isHidden == true)
    controller.updateResult(LastResult(text: "Blocked text", failure: .destinationChanged))
    #expect(controller.window?.title == "VoxKey Safety Net")
    #expect(root.label(containing: "Your words are still here.") != nil)
    #expect(root.label(containing: "choose Recover Dictation…") != nil)
    controller.updateResult(LastResult(text: "A new dictation"))
    #expect(root.label(containing: "Your dictation is ready.") != nil)
    #expect(root.label(containing: "choose Recover Dictation…") != nil)
}

@MainActor
@Test
func safetyNetRefreshesDisplayedAndCopiedResultTogether() throws {
    _ = NSApplication.shared
    let controller = SafetyNetWindowController(result: LastResult(text: "Older text"), destination: nil)
    let replacement = LastResult(text: "Newer text")
    controller.updateResult(replacement)
    let root = try #require(controller.window?.contentView)
    #expect(root.allDescendants.compactMap { $0 as? NSTextView }.first?.string == "Newer text")
    var copied: LastResult?
    controller.onCopy = { copied = $0 }
    root.button(titled: "Copy (⌘C)")?.performClick(nil)
    #expect(copied?.id == replacement.id)
    #expect(copied?.text == "Newer text")
}

@MainActor
@Test
func uncertainRecoveryRequiresCheckingTheDestination() throws {
    _ = NSApplication.shared
    let result = LastResult(text: "Potentially inserted", deliveryUncertain: true)
    let controller = SafetyNetWindowController(
        result: result, destination: DestinationLabel(applicationName: "TextEdit", processIdentifier: getpid())
    )
    let root = try #require(controller.window?.contentView)
    let deliver = try #require(root.button(titled: "Deliver"))
    #expect(!deliver.isEnabled)
    root.button(titled: "I checked the input; insert this text again")?.performClick(nil)
    #expect(deliver.isEnabled)
    var deliveries: [UUID] = []
    controller.onDeliver = { deliveries.append($0.id) }
    deliver.performClick(nil)
    deliver.performClick(nil)
    #expect(deliveries == [result.id])
}

@MainActor
@Test
func safetyNetCanRefreshItsRecoveryDestination() throws {
    _ = NSApplication.shared
    let controller = SafetyNetWindowController(
        result: LastResult(text: "Recovered text"),
        destination: nil
    )
    let root = try #require(controller.window?.contentView)

    #expect(root.button(titled: "Deliver")?.isEnabled == false)
    #expect(root.label(containing: "Copy your text, or focus an input") != nil)

    controller.updateDestination(
        DestinationLabel(applicationName: "TextEdit", processIdentifier: getpid())
    )

    #expect(root.button(titled: "Deliver")?.isEnabled == true)
    #expect(root.button(titled: "Deliver")?.isHidden == false)
    #expect(root.label(containing: "Return will deliver to TextEdit") != nil)
    controller.updateDestination(nil)
    #expect(root.button(titled: "Deliver")?.isHidden == true)
    #expect(root.button(titled: "Copy (⌘C)")?.isEnabled == true)
}

@MainActor
@Test(arguments: [false, true], [false, true])
func safetyNetKeepsRecoveryGuidanceAndActionsInsideTheWindow(uncertain: Bool, hasDestination: Bool) throws {
    _ = NSApplication.shared
    let controller = SafetyNetWindowController(
        result: LastResult(text: String(repeating: "A longer dictation. ", count: 100), deliveryUncertain: uncertain),
        destination: hasDestination
            ? DestinationLabel(applicationName: "An application with a longer display name", processIdentifier: getpid())
            : nil
    )
    let root = try #require(controller.window?.contentView)
    root.layoutSubtreeIfNeeded()
    let visibleControls = root.allDescendants.filter {
        ($0 is NSButton || $0 is NSTextField) && !$0.isHiddenOrHasHiddenAncestor
    }
    for control in visibleControls {
        let frame = root.convert(control.bounds, from: control)
        #expect(root.bounds.insetBy(dx: -1, dy: -1).contains(frame))
        #expect(frame.height > 0)
    }
    let guidance = try #require(root.label(containing: "This text may already be in your input"))
    #expect(guidance.isHiddenOrHasHiddenAncestor == !uncertain)
    controller.updateResult(LastResult(text: "A fresh result"))
    #expect(guidance.isHiddenOrHasHiddenAncestor)
    #expect(root.button(titled: "I checked the input; insert this text again")?.isHidden == true)
}

private extension NSView {
    var allDescendants: [NSView] {
        [self] + subviews.flatMap(\.allDescendants)
    }

    func button(titled title: String) -> NSButton? {
        allDescendants.compactMap { $0 as? NSButton }.first { $0.title == title }
    }

    func label(containing text: String) -> NSTextField? {
        allDescendants.compactMap { $0 as? NSTextField }.first { $0.stringValue.contains(text) }
    }
}
