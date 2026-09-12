import Foundation
#if DEBUG && VOXKEY_LOCAL_DIAGNOSTICS && !VOXKEY_RELEASE
import OSLog
#endif
import VoxKeyCore

struct CaptureTiming: Sendable {
    var initialSpeechTimeout: Duration = .seconds(3)
    var speechStartGrace: Duration = .milliseconds(300)
}

actor SessionCoordinator {
    #if DEBUG && VOXKEY_LOCAL_DIAGNOSTICS && !VOXKEY_RELEASE
    private let logger = Logger(subsystem: "com.rodrigouroz.VoxKey", category: "session")
    #endif

    let updates: AsyncStream<SessionSnapshot>
    let modelUpdates: AsyncStream<ModelPreparationPhase>
    let grammarUpdates: AsyncStream<GrammarCorrectionState>

    private let updateContinuation: AsyncStream<SessionSnapshot>.Continuation
    private let modelUpdateContinuation: AsyncStream<ModelPreparationPhase>.Continuation
    private let audioCapture: AudioCaptureService
    private let transcriber: WhisperTranscriber
    private let improver: TranscriptionImprover
    private var grammarCorrectionEnabled = false
    private var sessionGrammarCorrectionEnabled = false
    private let accessibility: AccessibilityService
    private let captureTiming: CaptureTiming
    private let cuePlayer: CaptureCuePlayer?
    private var armingCueTask: Task<Void, Never>?
    private var transcriptionTask: Task<TranscriptionOutcome, Error>?
    private var grammarSession: TranscriptionImprovementSession?
    private var captureStartTask: Task<Void, Error>?
    private var terminating = false

    private var machine: SessionStateMachine
    private var destinationToken: DestinationToken?
    private var recoveryToken: DestinationToken?
    private var captureStartedAt: ContinuousClock.Instant?
    private var releaseRequestedFor: DictationSessionID?
    private var inputLevelTask: Task<Void, Never>?
    private var inputLevel: Float?
    private var captureLimitTask: Task<Void, Never>?
    private var cancellingSessionID: DictationSessionID?
    private var modelReady = false
    private var modelPreparationInFlight = false
    private(set) var transcriptionConfiguration = TranscriptionConfiguration()
    private var sessionLanguage: String? = "en"
    private var snapshotDeduplicator = SnapshotDeduplicator()
    private var captureDestinationFailure: DeliveryFailure?
    private var sessionMicrophoneUID: String?
    private var sessionTrigger: DictationTrigger = .globe
    private var sessionVocabulary: [VocabularyTerm] = []
    private var recoveryDeliveryInFlight = false
    private var recoveryPreparationGeneration: UInt64 = 0

    @MainActor
    init(
        audioCapture: AudioCaptureService = AudioCaptureService(),
        transcriber: WhisperTranscriber = WhisperTranscriber(),
        accessibility: AccessibilityService = AccessibilityService(),
        initialState: SessionStateMachine = SessionStateMachine(),
        captureTiming: CaptureTiming = CaptureTiming(),
        cuePlayer: CaptureCuePlayer? = nil,
        grammarCorrector: GrammarCorrector = GrammarCorrector()
    ) {
        let stream = AsyncStream.makeStream(
            of: SessionSnapshot.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        updates = stream.stream
        updateContinuation = stream.continuation
        let modelStream = AsyncStream.makeStream(
            of: ModelPreparationPhase.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        modelUpdates = modelStream.stream
        modelUpdateContinuation = modelStream.continuation
        self.audioCapture = audioCapture
        self.transcriber = transcriber
        let improver = TranscriptionImprover(grammar: grammarCorrector)
        self.improver = improver
        grammarUpdates = improver.updates
        self.accessibility = accessibility
        self.captureTiming = captureTiming
        self.cuePlayer = cuePlayer
        machine = initialState
        updateContinuation.yield(machine.snapshot(message: "Complete setup to start dictating."))
        modelUpdateContinuation.yield(.required)
    }

    deinit {
        inputLevelTask?.cancel()
        inputLevelTask = nil
        captureLimitTask?.cancel()
        transcriptionTask?.cancel()
        grammarSession?.cancel()
        captureStartTask?.cancel()
        updateContinuation.finish()
        modelUpdateContinuation.finish()
    }

    func refreshReadiness() async {
        guard !machine.phase.isBusy, !modelPreparationInFlight else { return }
        guard AudioCaptureService.microphoneAuthorized() else {
            setNotReady(.microphonePermission, message: "Microphone access is required.")
            return
        }
        guard AccessibilityService.isTrusted else {
            setNotReady(.accessibilityPermission, message: "Accessibility access is required.")
            return
        }
        guard modelReady else {
            setNotReady(.modelUnavailable, message: "Prepare a transcription model.")
            return
        }
        if machine.phase == .ready { return }
        do {
            try machine.becomeReady()
            publish(message: "Ready")
        } catch {
            publish(message: "Finish the current dictation first.")
        }
    }

    func setGrammarCorrectionEnabled(_ enabled: Bool, download: Bool = false, repair: Bool = false) async {
        grammarCorrectionEnabled = enabled
        if !enabled {
            // Opting out invalidates this dictation even if opt-in returns before delivery.
            sessionGrammarCorrectionEnabled = false
            grammarSession?.cancel()
            grammarSession = nil
        }
        await improver.setEnabled(enabled, download: download, repair: repair)
    }

    func prepareDefaultModel(download: Bool = true) async throws {
        try await prepareModel(TranscriptionConfiguration(), download: download)
    }

    func prepareModel(_ configuration: TranscriptionConfiguration, download: Bool = true) async throws {
        guard !modelPreparationInFlight, !machine.phase.isBusy, !recoveryDeliveryInFlight, !terminating else {
            throw TranscriptionError.inferenceBusy
        }
        modelPreparationInFlight = true
        defer { modelPreparationInFlight = false }
        let previouslyReady = modelReady
        setNotReady(.modelUnavailable, message: "Preparing the transcription model…")
        do {
            let continuation = modelUpdateContinuation
            try await transcriber.prepare(model: configuration.model.rawValue, download: download) { phase in
                continuation.yield(phase)
            }
            transcriptionConfiguration = configuration
            modelReady = true
            modelUpdateContinuation.yield(.ready)
            modelPreparationInFlight = false
            await refreshReadiness()
        } catch {
            modelReady = previouslyReady
            modelUpdateContinuation.yield(previouslyReady ? .ready : (download ? .failed : .required))
            modelPreparationInFlight = false
            await refreshReadiness()
            throw error
        }
    }

    func triggerPressed(vocabulary: [VocabularyTerm] = [], captureMode: CaptureMode = .hold,
                        trigger: DictationTrigger = .globe, microphoneUID: String? = nil) async -> DictationSessionID? {
        #if DEBUG && VOXKEY_LOCAL_DIAGNOSTICS && !VOXKEY_RELEASE
        logger.notice("trigger session received phase=\(String(describing: self.machine.phase), privacy: .public) model_ready=\(self.modelReady, privacy: .public) preparing=\(self.modelPreparationInFlight, privacy: .public) terminating=\(self.terminating, privacy: .public) recovery=\(self.recoveryDeliveryInFlight, privacy: .public)")
        #endif
        if case let .finish(id) = machine.triggerPressAction {
            await stopAndProcess(id)
            return nil
        }
        guard !terminating, !modelPreparationInFlight, AudioCaptureService.microphoneAuthorized(), AccessibilityService.isTrusted, modelReady else {
            #if DEBUG && VOXKEY_LOCAL_DIAGNOSTICS && !VOXKEY_RELEASE
            logger.notice("trigger readiness rejected microphone=\(AudioCaptureService.microphoneAuthorized(), privacy: .public) accessibility=\(AccessibilityService.isTrusted, privacy: .public)")
            #endif
            await refreshReadiness()
            await rejectTrigger()
            return nil
        }
        guard machine.phase == .ready, !recoveryDeliveryInFlight else {
            publish(message: "VoxKey is busy.")
            await rejectTrigger()
            return nil
        }
        sessionGrammarCorrectionEnabled = grammarCorrectionEnabled && transcriptionConfiguration.supportsGrammarCorrection
        sessionLanguage = transcriptionConfiguration.decodingLanguage

        do {
            let sessionID = try machine.beginSession(captureMode: captureMode)
            sessionTrigger = trigger
            sessionMicrophoneUID = microphoneUID
            sessionVocabulary = vocabulary
            releaseRequestedFor = nil
            // Reserve the session before focus resolution can suspend. A quick
            // trigger release must be remembered while an AX tree wakes up.
            let assessment = await accessibility.captureCurrentDestination()
            #if DEBUG && VOXKEY_LOCAL_DIAGNOSTICS && !VOXKEY_RELEASE
            logger.notice("trigger destination resolved secure=\(assessment.kind == .secure, privacy: .public)")
            #endif
            guard machine.phase == .arming(sessionID) else {
                await accessibility.discard(assessment.token)
                return nil
            }
            if assessment.kind == .secure {
                try machine.finishWithoutResult(sessionID: sessionID)
                publish(message: "Dictation is blocked in secure fields.")
                await rejectTrigger()
                return nil
            }
            destinationToken = assessment.token
            captureDestinationFailure = assessment.failure
            publish(message: assessment.kind == .unknown ? "Destination uncertain" : "Starting…")
            return sessionID
        } catch {
            publish(message: "VoxKey is busy.")
            await rejectTrigger()
            return nil
        }
    }

    func observePotentialFocus(generation: UInt64) async {
        guard machine.phase == .ready else { return }
        await accessibility.observeCurrentFocus(generation: generation)
    }

    func startCapture(sessionID: DictationSessionID) async {
        #if DEBUG && VOXKEY_LOCAL_DIAGNOSTICS && !VOXKEY_RELEASE
        logger.notice("trigger capture requested phase=\(String(describing: self.machine.phase), privacy: .public) cancelling=\(self.cancellingSessionID != nil, privacy: .public) cue_pending=\(self.armingCueTask != nil, privacy: .public) capture_pending=\(self.captureStartTask != nil, privacy: .public)")
        #endif
        guard !terminating, machine.phase == .arming(sessionID), cancellingSessionID == nil,
              armingCueTask == nil, captureStartTask == nil else { return }
        if releaseRequestedFor != sessionID {
            let task = Task<Void, Never> { [cuePlayer] in await cuePlayer?.playStart() }
            armingCueTask = task
            await task.value
            guard machine.phase == .arming(sessionID) else { return }
            armingCueTask = nil
        }
        guard !terminating, machine.phase == .arming(sessionID), cancellingSessionID == nil else { return }
        if releaseRequestedFor == sessionID {
            await finishWithoutResult(sessionID, message: "Hold the trigger while speaking.")
            return
        }

        do {
            let microphoneUID = sessionMicrophoneUID
            let start = Task { [audioCapture] in
                try Task.checkCancellation()
                try await audioCapture.start(preferredUID: microphoneUID)
            }
            captureStartTask = start
            try await start.value
            captureStartTask = nil
            guard !terminating, machine.phase == .arming(sessionID), cancellingSessionID == nil else { return }
            inputLevel = 0
            try machine.beginCapture(sessionID: sessionID)
            captureStartedAt = .now
            let vocabulary = sessionVocabulary
            let correction = sessionGrammarCorrectionEnabled
                ? TranscriptionImprovementSession(improver: improver, requestID: sessionID.rawValue) : nil
            grammarSession = correction
            let language = sessionLanguage
            transcriptionTask = Task { [weak self, transcriber, audioCapture] in
                do {
                    return try await transcriber.transcribeStream(from: audioCapture, vocabulary: vocabulary, language: language) { _ in }
                } catch {
                    await self?.streamingFailed(sessionID)
                    throw error
                }
            }
            publish(message: nil)
            scheduleCaptureLimit(for: sessionID)
            scheduleInputLevels(for: sessionID)
            if releaseRequestedFor == sessionID { await stopAndProcess(sessionID) }
        } catch {
            captureStartTask = nil
            guard !terminating, cancellingSessionID == nil, machine.phase == .arming(sessionID) else { return }
            await audioCapture.cancel()
            await finishWithoutResult(sessionID, message: "Microphone capture could not start.")
        }
    }

    private func playEndCue() async {
        // The capture-limit task cancels itself during teardown. Closing feedback still
        // owns a bounded playback operation, and must finish before the next session.
        let playback = Task { [cuePlayer] in await cuePlayer?.playStop() }
        await playback.value
    }

    private func rejectTrigger() async {
        // Never play feedback into an open microphone or over an arming cue.
        guard captureStartedAt == nil, cancellingSessionID == nil else { return }
        if case .arming = machine.phase { return }
        if case .capturing = machine.phase { return }
        await cuePlayer?.playRejection()
    }

    func triggerReleased(sessionID: DictationSessionID) async {
        switch machine.triggerReleaseAction(sessionID: sessionID) {
        case .cancelArming:
            releaseRequestedFor = sessionID
            armingCueTask?.cancel()
        case .finish:
            await stopAndProcess(sessionID)
        case .ignore:
            break
        }
    }

    func cancel(expectedSessionID: DictationSessionID? = nil) async {
        guard let sessionID = machine.phase.activeSessionID else { return }
        guard expectedSessionID == nil || expectedSessionID == sessionID else { return }
        guard cancellingSessionID == nil else { return }
        switch machine.phase {
        case .arming, .capturing:
            // Keep the session busy while the microphone is closing. A key-up
            // racing the timeout must not start transcription during teardown.
            cancellingSessionID = sessionID
            defer { cancellingSessionID = nil }
            inputLevelTask?.cancel()
            inputLevelTask = nil
            captureLimitTask?.cancel()
            captureLimitTask = nil
            let hadCapture = captureStartedAt != nil
            armingCueTask?.cancel()
            await armingCueTask?.value
            armingCueTask = nil
            captureStartTask?.cancel()
            _ = await captureStartTask?.result
            captureStartTask = nil
            transcriptionTask?.cancel()
            grammarSession?.cancel()
            grammarSession = nil
            await audioCapture.cancel()
            _ = await transcriptionTask?.result
            transcriptionTask = nil
            if hadCapture { await playEndCue() }
            await accessibility.discard(destinationToken)
            destinationToken = nil
            captureStartedAt = nil
            releaseRequestedFor = nil
            try? machine.cancel(sessionID: sessionID)
            publish(message: "Cancelled")
        default:
            break
        }
    }

    func prepareRecoveryDestination(for resultID: UUID) async -> DestinationLabel? {
        guard !machine.phase.isBusy, !recoveryDeliveryInFlight, machine.lastResult?.id == resultID else { return nil }
        recoveryPreparationGeneration &+= 1
        let generation = recoveryPreparationGeneration
        let oldToken = recoveryToken
        recoveryToken = nil
        await accessibility.discard(oldToken)
        guard generation == recoveryPreparationGeneration else { return nil }
        let assessment = await accessibility.captureCurrentDestination()
        guard generation == recoveryPreparationGeneration,
              !machine.phase.isBusy, !recoveryDeliveryInFlight, machine.lastResult?.id == resultID else {
            await accessibility.discard(assessment.token)
            return nil
        }
        guard assessment.kind == .editable, let token = assessment.token else { return nil }
        recoveryToken = token
        return assessment.label
    }

    func deliverLastResult(id: UUID) async -> DeliveryOutcome {
        guard !machine.phase.isBusy, !recoveryDeliveryInFlight,
              let lastResult = machine.lastResult, lastResult.id == id, let recoveryToken else {
            return .failed(.destinationUnavailable)
        }
        recoveryDeliveryInFlight = true
        recoveryPreparationGeneration &+= 1
        self.recoveryToken = nil
        defer { recoveryDeliveryInFlight = false }
        let outcome = await accessibility.deliver(
            lastResult.text,
            to: recoveryToken,
            activateDestination: true
        )
        if outcome == .delivered, machine.lastResult?.id == id {
            machine.clearLastResult()
            publish(message: "Delivered")
        } else {
            if outcome == .unconfirmed {
                machine.markLastResultUncertain(id: id)
                publish(message: nil)
            }
            if case let .failed(reason) = outcome { publish(message: reason.recoveryMessage, attention: .deliveryBlocked(reason)) }
        }
        return outcome
    }

    func lastResult() -> LastResult? {
        machine.lastResult
    }

    func clearLastResult(id: UUID) async {
        guard !recoveryDeliveryInFlight, machine.lastResult?.id == id else { return }
        machine.clearLastResult()
        recoveryPreparationGeneration &+= 1
        let token = recoveryToken
        recoveryToken = nil
        publish(message: "Last result dismissed.")
        await accessibility.discard(token)
    }

    func currentSnapshot() -> SessionSnapshot {
        machine.snapshot(elapsedSeconds: elapsedSeconds, message: captureLimitMessage, trigger: sessionTrigger, inputLevel: capturingInputLevel)
    }

    func prepareForTermination() async {
        terminating = true
        inputLevelTask?.cancel()
        inputLevelTask = nil
        captureLimitTask?.cancel()
        armingCueTask?.cancel()
        captureStartTask?.cancel()
        transcriptionTask?.cancel()
        grammarSession?.cancel()
        grammarSession = nil
        await armingCueTask?.value
        _ = await captureStartTask?.result
        captureStartTask = nil
        await audioCapture.cancel()
        _ = await transcriptionTask?.result
        transcriptionTask = nil
        await improver.setEnabled(false)
        await accessibility.shutDown()
    }

    private func stopAndProcess(_ sessionID: DictationSessionID) async {
        guard !terminating, machine.phase == .capturing(sessionID), cancellingSessionID == nil else { return }
        defer {
            grammarSession?.cancel()
            grammarSession = nil
        }
        inputLevelTask?.cancel()
        inputLevelTask = nil
        captureLimitTask?.cancel()
        captureLimitTask = nil
        do {
            try machine.beginFinalization(sessionID: sessionID)
            try await audioCapture.finish()
            captureStartedAt = nil
            publish(message: "Transcribing…")
            guard let transcriptionTask else { throw TranscriptionError.emptyResult }
            #if DEBUG && VOXKEY_LOCAL_DIAGNOSTICS && !VOXKEY_RELEASE
            let released = ContinuousClock.now
            #endif
            await playEndCue()

            let transcription = try await transcriptionTask.value
            self.transcriptionTask = nil
            guard !terminating, machine.phase == .finalizing(sessionID) else { return }
            #if DEBUG && VOXKEY_LOCAL_DIAGNOSTICS && !VOXKEY_RELEASE
            let duration = released.duration(to: .now).components
            let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            logger.info("finalization seconds=\(seconds, privacy: .public)")
            #endif
            switch transcription {
            case .noSpeech:
                await accessibility.discard(destinationToken)
                destinationToken = nil
                try machine.finishWithoutResult(sessionID: sessionID)
                publish(message: "No speech detected")
            case let .final(text):
                if sessionGrammarCorrectionEnabled { publish(message: "Improving transcription…") }
                #if DEBUG && VOXKEY_LOCAL_DIAGNOSTICS && !VOXKEY_RELEASE
                let improvementStarted = ContinuousClock.now
                var deliveryTrace = TranscriptionDiagnostics.shared.begin(id: sessionID.rawValue, raw: text, event: "delivery")
                deliveryTrace?.status = "cancelled_before_delivery"
                deliveryTrace?.language = sessionLanguage ?? "auto"
                deliveryTrace?.recognitionFinalizationMilliseconds = seconds * 1000
                defer { TranscriptionDiagnostics.shared.save(deliveryTrace) }
                #endif
                let correctedText: String
                if let grammarSession { correctedText = await grammarSession.finish(text) }
                else { correctedText = text }
                #if DEBUG && VOXKEY_LOCAL_DIAGNOSTICS && !VOXKEY_RELEASE
                if sessionGrammarCorrectionEnabled {
                    let elapsed = improvementStarted.duration(to: .now).components
                    let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                    logger.info("improvement seconds=\(seconds, privacy: .public)")
                }
                #endif
                guard !terminating, machine.phase == .finalizing(sessionID) else { return }
                let deliveredText = grammarCorrectionEnabled && sessionGrammarCorrectionEnabled ? correctedText : text
                #if DEBUG && VOXKEY_LOCAL_DIAGNOSTICS && !VOXKEY_RELEASE
                deliveryTrace?.output = deliveredText
                deliveryTrace?.status = "delivery_started"
                #endif
                try machine.beginDelivery(sessionID: sessionID, text: deliveredText)
                publish(message: "Delivering…")
                guard let destinationToken else {
                    #if DEBUG && VOXKEY_LOCAL_DIAGNOSTICS && !VOXKEY_RELEASE
                    deliveryTrace?.status = "no_destination_token"
                    logger.notice("final result preserved reason=no_destination_token")
                    #endif
                    try finishWithoutDestination(sessionID: sessionID, reason: captureDestinationFailure)
                    return
                }
                self.destinationToken = nil
                #if DEBUG && VOXKEY_LOCAL_DIAGNOSTICS && !VOXKEY_RELEASE
                let deliveryStarted = ContinuousClock.now
                #endif
                let outcome = await accessibility.deliver(deliveredText, to: destinationToken)
                #if DEBUG && VOXKEY_LOCAL_DIAGNOSTICS && !VOXKEY_RELEASE
                deliveryTrace?.deliveryMilliseconds = TranscriptionDiagnostics.milliseconds(since: deliveryStarted)
                deliveryTrace?.status = String(describing: outcome)
                #endif
                switch outcome {
                case .delivered:
                    try machine.finishDelivery(sessionID: sessionID)
                    publish(message: "Delivered")
                case .unconfirmed:
                    try machine.finishDelivery(sessionID: sessionID, outcome: outcome)
                    publish(message: nil)
                case let .failed(reason):
                    #if DEBUG && VOXKEY_LOCAL_DIAGNOSTICS && !VOXKEY_RELEASE
                    logger.notice("final result preserved delivery_failure=\(String(describing: reason), privacy: .public)")
                    #endif
                    try machine.finishDelivery(sessionID: sessionID, outcome: outcome)
                    publish(message: reason.recoveryMessage, attention: .deliveryBlocked(reason))
                }
            }
        } catch {
            guard machine.phase.activeSessionID == sessionID else { return }
            let hadCapture = captureStartedAt != nil
            transcriptionTask?.cancel()
            await audioCapture.cancel()
            _ = await transcriptionTask?.result
            transcriptionTask = nil
            captureStartedAt = nil
            if hadCapture { await playEndCue() }
            await accessibility.discard(destinationToken)
            destinationToken = nil
            await finishWithoutResult(sessionID, message: "Dictation failed. Please try again.", attention: .processingFailed)
        }
    }

    private func streamingFailed(_ sessionID: DictationSessionID) async {
        guard !terminating, machine.phase == .capturing(sessionID), cancellingSessionID == nil else { return }
        cancellingSessionID = sessionID
        defer { cancellingSessionID = nil }
        inputLevelTask?.cancel()
        inputLevelTask = nil
        captureLimitTask?.cancel()
        captureLimitTask = nil
        await audioCapture.cancel()
        captureStartedAt = nil
        await playEndCue()
        // Called by the failed worker after inference unwinds; do not await that
        // same task here. The session remains busy until cleanup has completed.
        transcriptionTask = nil
        await finishWithoutResult(sessionID, message: "Dictation failed. Please try again.", attention: .processingFailed)
    }

    func finishWithoutDestination(sessionID: DictationSessionID, reason: DeliveryFailure?) throws {
        switch reason {
        case nil, .focusUnavailable, .unsupportedInsertion:
            guard let result = machine.lastResult else { throw SessionTransitionError.emptyLastResult }
            try machine.preserveLastResult(result.text, sessionID: sessionID)
            publish(message: "Your dictation is ready.", attention: .dictationReady)
        case let .some(reason):
            try machine.finishDelivery(sessionID: sessionID, outcome: .failed(reason))
            publish(message: reason.recoveryMessage, attention: .deliveryBlocked(reason))
        }
    }

    private func finishWithoutResult(_ sessionID: DictationSessionID, message: String, attention: SessionAttention? = nil) async {
        guard machine.phase.activeSessionID == sessionID else { return }
        grammarSession?.cancel()
        grammarSession = nil
        inputLevelTask?.cancel()
        inputLevelTask = nil
        captureLimitTask?.cancel()
        captureLimitTask = nil
        captureStartedAt = nil
        releaseRequestedFor = nil
        captureDestinationFailure = nil
        let token = destinationToken
        destinationToken = nil
        try? machine.finishWithoutResult(sessionID: sessionID)
        publish(message: message, attention: attention)
        await accessibility.discard(token)
    }

    private func scheduleCaptureLimit(for sessionID: DictationSessionID) {
        inputLevelTask?.cancel()
        inputLevelTask = nil
        captureLimitTask?.cancel()
        let startedAt = captureStartedAt ?? .now
        let initialSpeechTimeout = captureTiming.initialSpeechTimeout
        captureLimitTask = Task { [weak self] in
            try? await Task.sleep(until: startedAt.advanced(by: initialSpeechTimeout), clock: .continuous)
            guard !Task.isCancelled else { return }
            await self?.stopIfSpeechHasNotStarted(sessionID)
            guard !Task.isCancelled else { return }
            try? await Task.sleep(until: startedAt.advanced(by: .seconds(530)), clock: .continuous)
            guard !Task.isCancelled else { return }
            await self?.warnAboutCaptureLimit(sessionID)
            try? await Task.sleep(until: startedAt.advanced(by: .seconds(600)), clock: .continuous)
            guard !Task.isCancelled else { return }
            await self?.stopAndProcess(sessionID)
        }
    }

    private func stopIfSpeechHasNotStarted(_ sessionID: DictationSessionID) async {
        guard machine.phase == .capturing(sessionID), !Task.isCancelled else { return }
        var activity = await audioCapture.speechStartStatus()
        guard machine.phase == .capturing(sessionID), !Task.isCancelled else { return }
        if activity == .possibleSpeech {
            try? await Task.sleep(for: captureTiming.speechStartGrace)
            guard machine.phase == .capturing(sessionID), !Task.isCancelled else { return }
            activity = await audioCapture.speechStartStatus()
        }
        guard machine.phase == .capturing(sessionID), !Task.isCancelled, activity != .speech else { return }
        #if DEBUG && VOXKEY_LOCAL_DIAGNOSTICS && !VOXKEY_RELEASE
        logger.notice("capture cancelled reason=initial_silence")
        #endif
        let detectedAudio = await audioCapture.detectedAudio()
        guard machine.phase == .capturing(sessionID), !Task.isCancelled else { return }
        await cancel(expectedSessionID: sessionID)
        guard machine.phase == .ready else { return }
        publish(message: InitialSilenceMessage.text(detectedAudio: detectedAudio), attention: .noSpeech)
    }

    private func warnAboutCaptureLimit(_ sessionID: DictationSessionID) {
        guard machine.phase == .capturing(sessionID) else { return }
        publish(message: captureLimitMessage)
    }

    private func setNotReady(_ reason: NotReadyReason, message: String) {
        guard !machine.phase.isBusy else { return }
        try? machine.becomeNotReady(reason)
        publish(message: message)
    }

    private func scheduleInputLevels(for sessionID: DictationSessionID) {
        inputLevelTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                guard let self, await self.publishInputLevel(sessionID) else { return }
            }
        }
    }

    private func publishInputLevel(_ sessionID: DictationSessionID) async -> Bool {
        guard machine.phase == .capturing(sessionID), !Task.isCancelled else { return false }
        let level = await audioCapture.inputLevel()
        guard machine.phase == .capturing(sessionID), !Task.isCancelled else { return false }
        inputLevel = level
        publish(message: nil)
        return true
    }

    private var capturingInputLevel: Float? {
        if case .capturing = machine.phase { inputLevel ?? 0 } else { nil }
    }

    private var captureLimitMessage: String? {
        guard case .capturing = machine.phase, elapsedSeconds >= 530 else { return nil }
        let remaining = max(0, Int(ceil(600 - elapsedSeconds)))
        return String(format: "Dictation ends automatically in %d:%02d", remaining / 60, remaining % 60)
    }

    func microphoneFallbackUsed() async -> Bool { await audioCapture.usedDefaultFallback }

    func enforceCaptureSafety() async {
        if case let .capturing(id) = machine.phase, !(await audioCapture.inputIsAvailable()) {
            await stopAndProcess(id)
        }
        guard machine.phase.isBusy,
              !AudioCaptureService.microphoneAuthorized() || !AccessibilityService.isTrusted else { return }
        await cancel()
        await refreshReadiness()
    }

    private var elapsedSeconds: TimeInterval {
        guard let captureStartedAt else { return 0 }
        return captureStartedAt.duration(to: .now).seconds
    }

    private func publish(message: String?, attention: SessionAttention? = nil) {
        let snapshot = machine.snapshot(elapsedSeconds: elapsedSeconds, message: message ?? captureLimitMessage, attention: attention, trigger: sessionTrigger, inputLevel: capturingInputLevel)
        guard snapshotDeduplicator.accept(snapshot) else { return }
        updateContinuation.yield(snapshot)
    }
}

private extension Duration {
    var seconds: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
