import Foundation

public enum SessionTransitionError: Error, Equatable, Sendable {
    case invalidTransition(from: DictationPhase, operation: String)
    case staleSession(expected: DictationSessionID?, received: DictationSessionID)
    case emptyLastResult
}

public enum CaptureMode: String, Sendable { case hold, toggle }
public enum TriggerPressAction: Equatable, Sendable { case begin, finish(DictationSessionID), reject }
public enum TriggerReleaseAction: Equatable, Sendable { case cancelArming, finish, ignore }

public struct SessionStateMachine: Sendable {
    public private(set) var captureMode: CaptureMode

    public var triggerPressAction: TriggerPressAction {
        switch phase {
        case .ready: .begin
        case let .capturing(id) where captureMode == .toggle: .finish(id)
        default: .reject
        }
    }

    public func triggerReleaseAction(sessionID: DictationSessionID) -> TriggerReleaseAction {
        guard phase.activeSessionID == sessionID, captureMode == .hold else { return .ignore }
        switch phase {
        case .arming: return .cancelArming
        case .capturing: return .finish
        default: return .ignore
        }
    }

    public private(set) var phase: DictationPhase
    public private(set) var lastResult: LastResult?

    public init(phase: DictationPhase = .notReady(.onboarding), lastResult: LastResult? = nil, captureMode: CaptureMode = .hold) {
        self.captureMode = captureMode
        self.phase = phase
        self.lastResult = lastResult
    }

    public mutating func becomeReady() throws {
        guard !phase.isBusy else {
            throw SessionTransitionError.invalidTransition(from: phase, operation: "becomeReady")
        }
        phase = .ready
    }

    public mutating func becomeNotReady(_ reason: NotReadyReason) throws {
        guard !phase.isBusy else {
            throw SessionTransitionError.invalidTransition(from: phase, operation: "becomeNotReady")
        }
        phase = .notReady(reason)
    }

    @discardableResult
    public mutating func beginSession(id: DictationSessionID = DictationSessionID(), captureMode: CaptureMode = .hold) throws -> DictationSessionID {
        guard phase == .ready else {
            throw SessionTransitionError.invalidTransition(from: phase, operation: "beginSession")
        }
        self.captureMode = captureMode
        phase = .arming(id)
        return id
    }

    public mutating func beginCapture(sessionID: DictationSessionID) throws {
        try require(sessionID, phase: phase, expectedOperation: "beginCapture")
        guard case .arming = phase else {
            throw SessionTransitionError.invalidTransition(from: phase, operation: "beginCapture")
        }
        phase = .capturing(sessionID)
    }

    public mutating func beginFinalization(sessionID: DictationSessionID) throws {
        try require(sessionID, phase: phase, expectedOperation: "beginFinalization")
        guard case .capturing = phase else {
            throw SessionTransitionError.invalidTransition(from: phase, operation: "beginFinalization")
        }
        phase = .finalizing(sessionID)
    }

    public mutating func beginDelivery(sessionID: DictationSessionID, text: String? = nil) throws {
        try require(sessionID, phase: phase, expectedOperation: "beginDelivery")
        guard case .finalizing = phase else {
            throw SessionTransitionError.invalidTransition(from: phase, operation: "beginDelivery")
        }
        if let text {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SessionTransitionError.emptyLastResult }
            // Preserve the transcript before crossing the external write boundary.
            lastResult = LastResult(text: text, deliveryUncertain: true)
        }
        phase = .delivering(sessionID)
    }

    public mutating func finishDelivery(sessionID: DictationSessionID, outcome: DeliveryOutcome = .delivered) throws {
        try require(sessionID, phase: phase, expectedOperation: "finishDelivery")
        guard case .delivering = phase else {
            throw SessionTransitionError.invalidTransition(from: phase, operation: "finishDelivery")
        }
        if outcome == .delivered {
            lastResult = nil
        } else if let result = lastResult {
            let failure: DeliveryFailure? = if case let .failed(reason) = outcome { reason } else { nil }
            lastResult = LastResult(
                text: result.text, createdAt: result.createdAt, id: result.id,
                deliveryUncertain: failure == nil, failure: failure
            )
        }
        phase = .ready
    }

    public mutating func finishWithoutResult(sessionID: DictationSessionID) throws {
        try require(sessionID, phase: phase, expectedOperation: "finishWithoutResult")
        phase = .ready
    }

    public mutating func cancel(sessionID: DictationSessionID) throws {
        try require(sessionID, phase: phase, expectedOperation: "cancel")
        guard isArmingOrCapturing(phase) else {
            throw SessionTransitionError.invalidTransition(from: phase, operation: "cancel")
        }
        phase = .ready
    }

    public mutating func preserveLastResult(_ text: String, sessionID: DictationSessionID, deliveryUncertain: Bool = false) throws {
        try require(sessionID, phase: phase, expectedOperation: "preserveLastResult")
        guard case .delivering = phase else {
            throw SessionTransitionError.invalidTransition(from: phase, operation: "preserveLastResult")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SessionTransitionError.emptyLastResult }
        lastResult = LastResult(text: trimmed, deliveryUncertain: deliveryUncertain)
        phase = .ready
    }

    public mutating func clearLastResult() {
        lastResult = nil
    }

    public mutating func markLastResultUncertain(id: UUID) {
        guard let result = lastResult, result.id == id else { return }
        lastResult = LastResult(text: result.text, createdAt: result.createdAt, id: id, deliveryUncertain: true)
    }

    public func snapshot(elapsedSeconds: TimeInterval = 0, message: String? = nil, attention: SessionAttention? = nil, trigger: DictationTrigger = .globe, inputLevel: Float? = nil) -> SessionSnapshot {
        SessionSnapshot(phase: phase, lastResult: lastResult, elapsedSeconds: elapsedSeconds, message: message, attention: attention, captureMode: captureMode, trigger: trigger, inputLevel: inputLevel)
    }

    private func require(
        _ received: DictationSessionID,
        phase: DictationPhase,
        expectedOperation: String
    ) throws {
        guard phase.activeSessionID == received else {
            throw SessionTransitionError.staleSession(expected: phase.activeSessionID, received: received)
        }
    }

    private func isArmingOrCapturing(_ phase: DictationPhase) -> Bool {
        switch phase {
        case .arming, .capturing: true
        default: false
        }
    }
}
