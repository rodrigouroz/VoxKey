import Foundation

public struct DictationSessionID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString }
}

public enum NotReadyReason: Equatable, Sendable {
    case onboarding
    case microphonePermission
    case accessibilityPermission
    case modelUnavailable
}

public enum DictationPhase: Equatable, Sendable {
    case notReady(NotReadyReason)
    case ready
    case arming(DictationSessionID)
    case capturing(DictationSessionID)
    case finalizing(DictationSessionID)
    case delivering(DictationSessionID)

    public var activeSessionID: DictationSessionID? {
        switch self {
        case let .arming(id), let .capturing(id), let .finalizing(id), let .delivering(id): id
        case .notReady, .ready: nil
        }
    }

    public var isBusy: Bool { activeSessionID != nil }
}

public struct LastResult: Equatable, Sendable {
    public let id: UUID
    public let text: String
    public let createdAt: Date
    public let deliveryUncertain: Bool
    public let failure: DeliveryFailure?

    public init(text: String, createdAt: Date = Date(), id: UUID = UUID(), deliveryUncertain: Bool = false, failure: DeliveryFailure? = nil) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.deliveryUncertain = deliveryUncertain
        self.failure = failure
    }
}

public enum SessionAttention: Equatable, Sendable {
    case dictationReady
    case deliveryBlocked(DeliveryFailure)
    case processingFailed
    case noSpeech
}

public struct SessionSnapshot: Equatable, Sendable {
    public let phase: DictationPhase
    public let lastResult: LastResult?
    public let inputLevel: Float?
    public let captureMode: CaptureMode
    public let trigger: DictationTrigger
    public let elapsedSeconds: TimeInterval
    public let message: String?
    public let attention: SessionAttention?

    public init(
        phase: DictationPhase,
        lastResult: LastResult?,
        elapsedSeconds: TimeInterval = 0,
        message: String? = nil,
        attention: SessionAttention? = nil,
        captureMode: CaptureMode = .hold,
        trigger: DictationTrigger = .globe,
        inputLevel: Float? = nil
    ) {
        self.inputLevel = inputLevel
        self.captureMode = captureMode
        self.trigger = trigger
        self.phase = phase
        self.lastResult = lastResult
        self.elapsedSeconds = elapsedSeconds
        self.message = message
        self.attention = attention
    }
}

public struct SnapshotDeduplicator: Sendable {
    private var lastSnapshot: SessionSnapshot?

    public init() {}

    public mutating func accept(_ snapshot: SessionSnapshot) -> Bool {
        guard snapshot != lastSnapshot else { return false }
        lastSnapshot = snapshot
        return true
    }
}

public enum ModelPreparationPhase: Equatable, Sendable {
    case required
    case downloading(Double)
    case prewarming
    case ready
    case failed
}

public enum DestinationKind: Equatable, Sendable {
    case editable
    case secure
    case unknown
}

public struct DestinationLabel: Equatable, Sendable {
    public let applicationName: String
    public let processIdentifier: Int32

    public init(applicationName: String, processIdentifier: Int32) {
        self.applicationName = applicationName
        self.processIdentifier = processIdentifier
    }
}

public struct DestinationToken: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct DestinationAssessment: Equatable, Sendable {
    public let kind: DestinationKind
    public let token: DestinationToken?
    public let label: DestinationLabel?
    public let failure: DeliveryFailure?

    public init(kind: DestinationKind, token: DestinationToken?, label: DestinationLabel?, failure: DeliveryFailure? = nil) {
        self.kind = kind
        self.token = token
        self.label = label
        self.failure = failure
    }
}

public enum DeliveryFailure: Error, Equatable, Sendable {
    case permissionsUnavailable
    case focusUnavailable
    case selectionUnavailable
    case inputBusy
    case destinationUnavailable
    case destinationChanged
    case editingConflict
    case secureDestination
    case unsupportedInsertion
    case pasteboardChanged

    public var recoveryMessage: String {
        switch self {
        case .permissionsUnavailable: "Accessibility access is required. Your text is in Safety Net."
        case .focusUnavailable: "Couldn’t identify the focused input. Your text is in Safety Net."
        case .selectionUnavailable: "Couldn’t read the insertion point. Your text is in Safety Net."
        case .inputBusy: "Release the keyboard modifiers, then use Safety Net."
        case .destinationChanged: "Focus changed. Your text is in Safety Net."
        case .editingConflict: "The insertion point or text changed. Your text is in Safety Net."
        case .secureDestination: "Dictation is blocked in secure fields."
        case .unsupportedInsertion: "This input couldn’t accept dictation. Your text is in Safety Net."
        case .pasteboardChanged: "The clipboard changed. Your text is in Safety Net."
        case .destinationUnavailable: "The destination is unavailable. Your text is in Safety Net."
        }
    }
}

public enum DeliveryOutcome: Equatable, Sendable {
    case delivered
    /// A write may have applied. This is not a failure and must never authorize an automatic retry.
    case unconfirmed
    /// The request was blocked or explicitly rejected before a possibly applied write.
    case failed(DeliveryFailure)
}

public struct CapturedAudio: Sendable {
    public let samples: [Float]
    public let sampleRate: Double
    public let overflowed: Bool

    public init(samples: [Float], sampleRate: Double, overflowed: Bool) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.overflowed = overflowed
    }

    public var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(samples.count) / sampleRate
    }
}

public enum TranscriptionOutcome: Equatable, Sendable {
    case final(String)
    case noSpeech
}
