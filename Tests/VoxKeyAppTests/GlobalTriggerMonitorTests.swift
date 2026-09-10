import ApplicationServices
import Testing
@testable import VoxKeyApp

@Test
func mouseReleaseSignalsPotentialFocus() {
    #expect(FocusSignalClassifier.shouldObserve(type: .leftMouseUp, keyCode: nil, flags: []))
    #expect(FocusSignalClassifier.shouldObserve(type: .rightMouseUp, keyCode: nil, flags: []))
    #expect(FocusSignalClassifier.shouldObserve(type: .otherMouseUp, keyCode: nil, flags: []))
}

@Test
func keyboardNavigationAndCommandsSignalPotentialFocus() {
    #expect(FocusSignalClassifier.shouldObserve(type: .keyUp, keyCode: 48, flags: []))
    #expect(FocusSignalClassifier.shouldObserve(type: .keyUp, keyCode: 9, flags: .maskCommand))
    #expect(FocusSignalClassifier.shouldObserve(type: .keyUp, keyCode: 123, flags: .maskControl))
    #expect(FocusSignalClassifier.shouldObserve(type: .keyUp, keyCode: 124, flags: .maskAlternate))
}

@Test
func ordinaryTypingAndTheDictationModifierDoNotResampleFocus() {
    #expect(!FocusSignalClassifier.shouldObserve(type: .keyUp, keyCode: 0, flags: []))
    #expect(!FocusSignalClassifier.shouldObserve(
        type: .flagsChanged,
        keyCode: nil,
        flags: .maskSecondaryFn
    ))
}

import VoxKeyCore

@Test(arguments: [DictationTrigger.globe, .rightOption, .rightCommand, .rightControl])
func onlyTheSelectedModifierStartsAndReleases(_ trigger: DictationTrigger) {
    var classifier = TriggerClassifier()
    let flags = triggerFlags(trigger)
    #expect(classifier.classify(type: .flagsChanged, keyCode: trigger.keyCode, flags: flags, trigger: trigger) == .pending)
    #expect(classifier.acceptPendingPress() == .pressed)
    // Changing the preference during a hold retains ownership until its release.
    #expect(classifier.classify(type: .flagsChanged, keyCode: trigger.keyCode, flags: [], trigger: .globe) == .released)
    #expect(classifier.classify(type: .flagsChanged, keyCode: trigger.keyCode, flags: [], trigger: trigger) == nil)
}

@Test(arguments: [DictationTrigger.rightOption, .rightCommand, .rightControl])
func leftModifiersAndCapsLockNeverActivate(_ trigger: DictationTrigger) {
    var classifier = TriggerClassifier()
    for key: UInt16 in [58, 55, 59, 57] {
        #expect(classifier.classify(type: .flagsChanged, keyCode: key, flags: triggerFlags(trigger), trigger: trigger) == nil)
        #expect(classifier.acceptPendingPress() == nil)
    }
}

@Test(arguments: [false, true])
func aChordDuringTheDetectionWindowDoesNotStartOrRelease(_ modifierFirst: Bool) {
    var classifier = TriggerClassifier()
    if !modifierFirst { _ = classifier.classify(type: .keyDown, keyCode: 0, flags: [], trigger: .rightCommand) }
    _ = classifier.classify(type: .flagsChanged, keyCode: 54, flags: triggerFlags(.rightCommand), trigger: .rightCommand)
    if modifierFirst { _ = classifier.classify(type: .keyDown, keyCode: 0, flags: triggerFlags(.rightCommand), trigger: .rightCommand) }
    #expect(classifier.acceptPendingPress() == nil)
    #expect(classifier.classify(type: .flagsChanged, keyCode: 54, flags: [], trigger: .rightCommand) == nil)
}

@Test
func joiningAChordAfterActivationCancelsRatherThanDelivering() {
    var classifier = TriggerClassifier()
    _ = classifier.classify(type: .flagsChanged, keyCode: 61, flags: triggerFlags(.rightOption), trigger: .rightOption)
    #expect(classifier.acceptPendingPress() == .pressed)
    #expect(classifier.classify(type: .keyDown, keyCode: 0, flags: triggerFlags(.rightOption), trigger: .rightOption) == .cancelled)
    #expect(classifier.classify(type: .flagsChanged, keyCode: 61, flags: [], trigger: .rightOption) == nil)
}

@Test
func rightReleaseIsRecognizedEvenWhenLeftModifierRemainsDown() {
    var classifier = TriggerClassifier()
    _ = classifier.classify(type: .flagsChanged, keyCode: 62, flags: triggerFlags(.rightControl), trigger: .rightControl)
    #expect(classifier.acceptPendingPress() == .pressed)
    #expect(classifier.classify(type: .flagsChanged, keyCode: 62, flags: CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 1), trigger: .rightControl) == .released)
}

private func triggerFlags(_ trigger: DictationTrigger) -> CGEventFlags {
    switch trigger {
    case .globe: .maskSecondaryFn
    case .rightOption: CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40)
    case .rightCommand: CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10)
    case .rightControl: CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x2000)
    }
}
