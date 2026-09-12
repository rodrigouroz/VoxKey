import Foundation

/// Optional final-transcript editing. Preparation never blocks capture. Each
/// session is tied to the opt-in generation; disable/re-enable cannot revive it.
actor TranscriptionImprover {
    static let preferenceKey = "VoxKeyImproveTranscriptionEnabled"
    nonisolated let updates: AsyncStream<GrammarCorrectionState>
    private let continuation: AsyncStream<GrammarCorrectionState>.Continuation
    private let grammar: GrammarCorrector
    private let store: S1ModelStore
    private let runtime: S1Runtime
    private let suppliedModel: URL?
    #if DEBUG && VOXKEY_LOCAL_DIAGNOSTICS && !VOXKEY_RELEASE
    private var diagnostics = TranscriptionDiagnostics.shared
    func setDiagnostics(_ store: TranscriptionDiagnostics) { diagnostics = store }
    #endif
    private var preparation: Task<Void, Never>?
    private var observation: Task<Void, Never>?
    private var enabled = false
    private var preparingGrammar = false
    private(set) var ready = false
    private(set) var generation = 0

    init(grammar: GrammarCorrector = GrammarCorrector(), store: S1ModelStore = S1ModelStore(),
         runtime: S1Runtime = S1Runtime(), model: URL? = nil) {
        self.grammar = grammar
        self.store = store
        self.runtime = runtime
        suppliedModel = model
        let stream = AsyncStream.makeStream(of: GrammarCorrectionState.self, bufferingPolicy: .bufferingNewest(1))
        updates = stream.stream
        continuation = stream.continuation
        continuation.yield(.off)
    }

    deinit { preparation?.cancel(); observation?.cancel(); continuation.finish() }

    func setEnabled(_ value: Bool, download: Bool = false, repair: Bool = false) async {
        guard enabled != value || download else { return }
        enabled = value
        ready = false
        generation += 1
        let request = generation
        let previous = preparation
        previous?.cancel()
        preparingGrammar = value
        continuation.yield(value ? .waiting : .off)
        if observation == nil {
            observation = Task { [weak self, grammar] in
                for await state in grammar.updates {
                    guard !Task.isCancelled else { return }
                    await self?.grammarProgress(state)
                }
            }
        }
        await runtime.stop()
        guard request == generation else { return }
        await grammar.setEnabled(value, download: download, repair: repair)
        guard value, request == generation else { return }
        preparation = Task { [weak self] in
            await previous?.value
            await self?.prepare(generation: request, download: download, repair: repair)
        }
    }

    /// Settings can return immediately; tests may await actual model readiness.
    func waitForPreparation() async { await preparation?.value }

    private func current(_ request: Int) -> Bool { enabled && generation == request && !Task.isCancelled }

    private func grammarProgress(_ state: GrammarCorrectionState) {
        guard enabled, preparingGrammar else { return }
        // The public state describes the whole pipeline, so GECToR readiness
        // alone must never light up the combined feature's ready indicator.
        if state == .ready || state == .off { return }
        if case let .downloading(fraction) = state { continuation.yield(.downloading(fraction * 0.256)) }
        else { continuation.yield(state) }
    }

    private func prepare(generation request: Int, download: Bool, repair: Bool) async {
        guard current(request) else { return }
        let grammarAvailable = await grammar.waitForPreparation()
        guard current(request) else { return }
        guard grammarAvailable else {
            let state = await grammar.state
            guard current(request) else { return }
            continuation.yield(state == .downloadRequired ? .downloadRequired : .unavailable)
            return
        }
        await grammar.warmUp(enabledForSession: true)
        guard current(request) else { return }
        let grammarLoaded = await grammar.isLoaded
        guard current(request), grammarLoaded else {
            if current(request) { continuation.yield(.unavailable) }
            return
        }
        preparingGrammar = false
        do {
            let model: URL
            if let suppliedModel { model = suppliedModel }
            else {
                model = try await store.prepare(download: download, repair: repair) { [weak self] fraction in
                    Task { await self?.downloadProgress(fraction, generation: request) }
                }
            }
            guard current(request) else { return }
            continuation.yield(.loading)
            try await runtime.start(model: model)
            guard current(request) else { return }
            // Finish lazy Metal/decoder setup before the first real dictation.
            _ = try await runtime.improve("Please send the report tomorrow.")
            guard current(request) else { return }
            ready = true
            continuation.yield(.ready)
        } catch {
            guard current(request) else { return }
            ready = false
            continuation.yield(error as? GrammarInstallationError == .downloadRequired ? .downloadRequired : .unavailable)
        }
    }

    private func downloadProgress(_ fraction: Double, generation request: Int) {
        guard current(request), !ready else { return }
        continuation.yield(.downloading(0.256 + fraction * 0.744))
    }

    func improve(_ original: String, generation request: Int, requestID: UUID = UUID()) async -> String {
        #if DEBUG && VOXKEY_LOCAL_DIAGNOSTICS && !VOXKEY_RELEASE
        let traceStore = diagnostics
        var trace = traceStore.begin(id: requestID, raw: original)
        let started = ContinuousClock.now
        defer {
            trace?.totalMilliseconds = TranscriptionDiagnostics.milliseconds(since: started)
            traceStore.save(trace)
        }
        trace?.status = !enabled ? "disabled" : generation != request ? "stale_generation" : Task.isCancelled ? "cancelled" : original.isEmpty ? "empty" : "not_ready"
        #endif
        guard current(request), ready, !original.isEmpty else { return original }
        do {
            #if DEBUG && VOXKEY_LOCAL_DIAGNOSTICS && !VOXKEY_RELEASE
            trace?.status = "s1_started"
            let s1Started = ContinuousClock.now
            let generated = try await runtime.generate(original)
            let proposed = generated.text
            trace?.s1 = proposed
            trace?.s1Milliseconds = TranscriptionDiagnostics.milliseconds(since: s1Started)
            trace?.proposedTokens = generated.proposed
            trace?.acceptedTokens = generated.accepted
            trace?.status = "invalidated_after_s1"
            #else
            let proposed = try await runtime.improve(original)
            #endif
            guard current(request), ready else { return original }
            let rejected = TranscriptionImprovementGuard.rejects(original: original, candidate: proposed)
            let source = rejected ? original : proposed
            #if DEBUG && VOXKEY_LOCAL_DIAGNOSTICS && !VOXKEY_RELEASE
            trace?.s1Rejected = rejected
            trace?.grammarInput = source
            trace?.status = "gector_started"
            let gectorStarted = ContinuousClock.now
            #endif
            let corrected = await grammar.correctUsingCache(source, enabledForSession: true, cache: .init())
            #if DEBUG && VOXKEY_LOCAL_DIAGNOSTICS && !VOXKEY_RELEASE
            trace?.gector = corrected.text
            trace?.gectorMilliseconds = TranscriptionDiagnostics.milliseconds(since: gectorStarted)
            trace?.status = "invalidated_after_gector"
            #endif
            guard current(request), ready else { return original }
            guard corrected.completed else {
                #if DEBUG && VOXKEY_LOCAL_DIAGNOSTICS && !VOXKEY_RELEASE
                trace?.status = "gector_failed_or_rejected_input"
                #endif
                continuation.yield(.unavailable)
                return original
            }
            let result = TranscriptionImprovementGuard.restrictGrammar(source: source, proposal: corrected.text)
            #if DEBUG && VOXKEY_LOCAL_DIAGNOSTICS && !VOXKEY_RELEASE
            trace?.output = result
            trace?.status = rejected ? "completed_s1_guard_fallback" : "completed"
            #endif
            continuation.yield(.ready)
            return result
        } catch {
            #if DEBUG && VOXKEY_LOCAL_DIAGNOSTICS && !VOXKEY_RELEASE
            trace?.status = error is CancellationError ? "cancelled" : "s1_failure_\(String(describing: error as? S1Runtime.Failure))"
            #endif
            // Cancellation can destroy the native context. Recover independently
            // of the cancelled dictation so the next capture can improve again.
            let runtimeReady = await runtime.isReady
            if enabled, generation == request {
                if runtimeReady {
                    if !Task.isCancelled { continuation.yield(.ready) }
                } else {
                    ready = false
                    continuation.yield(.loading)
                    preparation = Task { [weak self] in
                        await self?.prepare(generation: request, download: false, repair: false)
                    }
                }
            }
            return original
        }
    }
}

/// No prefix editing: the final S1 rewrite needs the entire recognized context.
final class TranscriptionImprovementSession: Sendable {
    private let continuation: AsyncStream<String>.Continuation
    private let worker: Task<String?, Never>

    init(improver: TranscriptionImprover, requestID: UUID = UUID()) {
        let stream = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(1))
        continuation = stream.continuation
        worker = Task(priority: .utility) {
            let generation = await improver.generation
            for await original in stream.stream {
                guard !Task.isCancelled else { return nil }
                let result = await improver.improve(original, generation: generation, requestID: requestID)
                return Task.isCancelled ? nil : result
            }
            return nil
        }
    }

    deinit { cancel() }
    func finish(_ original: String) async -> String {
        continuation.yield(original)
        continuation.finish()
        return await worker.value ?? original
    }
    func cancel() { continuation.finish(); worker.cancel() }
}
