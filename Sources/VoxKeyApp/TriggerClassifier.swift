import ApplicationServices
import VoxKeyCore

/// Only event values enter this classifier; no event tap, timers, or permissions.
struct TriggerClassifier {
    enum Action: Equatable { case pending, pressed, released, cancelled }
    private var heldKeys: Set<CGKeyCode> = []
    private var activeTrigger: DictationTrigger?
    private var accepted = false
    private var chord = false

    mutating func classify(type: CGEventType, keyCode: CGKeyCode, flags: CGEventFlags,
                           trigger: DictationTrigger) -> Action? {
        if type == .keyUp { heldKeys.remove(keyCode); return nil }
        if type == .keyDown {
            heldKeys.insert(keyCode)
            return rejectChord()
        }
        guard type == .flagsChanged else { return nil }
        let selected = activeTrigger ?? trigger
        guard keyCode == selected.keyCode else {
            // Even the opposite modifier of the same family is a chord.
            return rejectChord()
        }
        // Device-specific flags distinguish releasing the right key while its left
        // counterpart is still down. The keycode alone identifies which key changed.
        let rightDown = flags.rawValue & selected.deviceMask != 0
        if activeTrigger != nil, !rightDown {
            let release = accepted && !chord
            activeTrigger = nil
            accepted = false
            chord = false
            return release ? .released : nil
        }
        guard activeTrigger == nil, rightDown else { return nil }
        activeTrigger = selected
        let otherModifiers = flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn])
            .subtracting(selected.familyMask)
        let leftDown = flags.rawValue & selected.oppositeDeviceMask != 0
        chord = !heldKeys.isEmpty || !otherModifiers.isEmpty || leftDown
        return chord ? nil : .pending
    }

    mutating func acceptPendingPress() -> Action? {
        guard activeTrigger != nil, !accepted, !chord else { return nil }
        accepted = true
        return .pressed
    }

    private mutating func rejectChord() -> Action? {
        guard activeTrigger != nil, !chord else { return nil }
        chord = true
        return accepted ? .cancelled : nil
    }
}

private extension DictationTrigger {
    var deviceMask: UInt64 {
        switch self {
        case .globe: CGEventFlags.maskSecondaryFn.rawValue
        case .rightOption: 0x40
        case .rightCommand: 0x10
        case .rightControl: 0x2000
        }
    }
    var oppositeDeviceMask: UInt64 {
        switch self {
        case .globe: 0
        case .rightOption: 0x20
        case .rightCommand: 0x8
        case .rightControl: 0x1
        }
    }
    var familyMask: CGEventFlags {
        switch self {
        case .globe: .maskSecondaryFn
        case .rightOption: .maskAlternate
        case .rightCommand: .maskCommand
        case .rightControl: .maskControl
        }
    }
}
