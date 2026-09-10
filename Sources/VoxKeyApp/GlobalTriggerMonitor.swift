@preconcurrency import AppKit
import ApplicationServices
import Foundation
import VoxKeyCore

@MainActor
final class GlobalTriggerMonitor {
    var onPress: (@MainActor @Sendable () -> Void)?
    var onRelease: (@MainActor @Sendable () -> Void)?
    var onCancel: (@MainActor @Sendable () -> Void)?
    var onFocusSignal: (@MainActor @Sendable () -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    var trigger: DictationTrigger = .globe
    private var classifier = TriggerClassifier()
    private var pendingPress: Task<Void, Never>?

    func start() throws {
        guard eventTap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
            | CGEventMask(1 << CGEventType.rightMouseUp.rawValue)
            | CGEventMask(1 << CGEventType.otherMouseUp.rawValue)

        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<GlobalTriggerMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                MainActor.assumeIsolated {
                    monitor.handle(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: pointer
        ) else {
            throw TriggerError.eventTapUnavailable(trigger)
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
        classifier = TriggerClassifier()
        pendingPress?.cancel()
        pendingPress = nil
    }

    private func handle(type: CGEventType, event: CGEvent) {
        let keyCode = type == .keyDown || type == .keyUp
            ? CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            : nil
        if FocusSignalClassifier.shouldObserve(type: type, keyCode: keyCode, flags: event.flags) {
            onFocusSignal?()
        }

        if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 53 {
            pendingPress?.cancel()
            _ = classifier.classify(type: type, keyCode: 53, flags: event.flags, trigger: trigger)
            onCancel?()
            return
        }

        let action = classifier.classify(
            type: type, keyCode: CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)),
            flags: event.flags, trigger: trigger
        )
        switch action {
        case .pending:
            pendingPress?.cancel()
            pendingPress = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let self,
                      classifier.acceptPendingPress() == .pressed else { return }
                onPress?()
            }
        case .released: onRelease?()
        case .cancelled: onCancel?()
        case .pressed, nil: break
        }
    }
}

enum FocusSignalClassifier {
    private static let tabKeyCode: CGKeyCode = 48
    private static let focusChangingModifiers: CGEventFlags = [
        .maskCommand,
        .maskControl,
        .maskAlternate
    ]

    static func shouldObserve(
        type: CGEventType,
        keyCode: CGKeyCode?,
        flags: CGEventFlags
    ) -> Bool {
        switch type {
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            true
        case .keyUp:
            keyCode == tabKeyCode || !flags.intersection(focusChangingModifiers).isEmpty
        default:
            false
        }
    }
}

enum TriggerError: Error, LocalizedError {
    case eventTapUnavailable(DictationTrigger)

    var errorDescription: String? {
        switch self {
        case let .eventTapUnavailable(trigger): "The global \(trigger.displayName) trigger could not be installed."
        }
    }
}
