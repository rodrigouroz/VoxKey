@preconcurrency import AVFoundation
import Foundation
#if DEBUG && VOXKEY_LOCAL_DIAGNOSTICS && !VOXKEY_RELEASE
import OSLog
#endif
@preconcurrency import WhisperKit
import VoxKeyCore

enum TranscriptionError: Error, LocalizedError {
    case modelNotLoaded
    case modelNotInstalled
    case invalidAudio
    case resamplingFailed
    case emptyResult
    case inferenceBusy
    case streamingBacklog

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: "The selected transcription model is not ready."
        case .modelNotInstalled: "The selected transcription model is not installed."
        case .invalidAudio: "The captured audio is invalid."
        case .resamplingFailed: "The captured audio could not be prepared for transcription."
        case .emptyResult: "The model did not return a transcription result."
        case .inferenceBusy: "The transcription model is already in use."
        case .streamingBacklog: "Transcription could not keep up with the microphone."
        }
    }
}

actor WhisperTranscriber {
    static let defaultModel = "distil-whisper_distil-large-v3_594MB"
    static let fullModel = "distil-whisper_distil-large-v3"
    static let targetSampleRate = 16_000.0

    private var whisperKit: WhisperKit?
    private let computeOptions: ModelComputeOptions?
    private let localModelRoot: URL?
    private var inferenceInFlight = false
    private var preparationInFlight = false
    private var previewTask: Task<Void, Never>?
    private var previewObserver: DecoderPreviewObserver?
    private var previewRunning = false
    #if DEBUG && VOXKEY_LOCAL_DIAGNOSTICS && !VOXKEY_RELEASE
    private let logger = Logger(subsystem: "com.rodrigouroz.VoxKey", category: "transcription")
    #endif
    private(set) var selectedModel = defaultModel

    // Let Core ML use all available processors, including
    // the GPU: local end-to-end measurements substantially favor it on M5 Pro.
    init(computeOptions: ModelComputeOptions? = ModelComputeOptions(
        audioEncoderCompute: .all, textDecoderCompute: .all
    ), localModelRoot: URL? = nil) {
        self.computeOptions = computeOptions
        self.localModelRoot = localModelRoot
    }

    func prepare(
        model: String = defaultModel,
        download: Bool = true,
        progress: @escaping @Sendable (ModelPreparationPhase) -> Void = { _ in }
    ) async throws {
        guard !inferenceInFlight, !preparationInFlight else { throw TranscriptionError.inferenceBusy }
        if whisperKit != nil, selectedModel == model { return }
        preparationInFlight = true
        defer { preparationInFlight = false }

        let downloadBase = try TranscriptionModelFiles.downloadBase()
        let modelFolder: URL
        if download {
            progress(.downloading(0))
            modelFolder = try await WhisperKit.download(
                variant: model,
                downloadBase: downloadBase
            ) { downloadProgress in
                progress(.downloading(downloadProgress.fractionCompleted))
            }
        } else {
            modelFolder = try TranscriptionModelFiles(root: localModelRoot).folder(for: model)
            guard TranscriptionModelFiles.isComplete(at: modelFolder) else {
                throw TranscriptionError.modelNotInstalled
            }
        }

        guard TranscriptionModelFiles.isComplete(at: modelFolder) else {
            throw TranscriptionError.modelNotInstalled
        }
        progress(.prewarming)
        let config = WhisperKitConfig(
            model: model,
            downloadBase: downloadBase,
            modelFolder: modelFolder.path,
            computeOptions: computeOptions,
            verbose: false,
            logLevel: .none,
            prewarm: true,
            load: true,
            download: false
        )
        let candidate = try await WhisperKit(config)
        try Task.checkCancellation()
        whisperKit = candidate
        selectedModel = model
    }

    func vocabularyPromptTokens(_ terms: [VocabularyTerm]) throws -> [Int] {
        guard let tokenizer = whisperKit?.tokenizer else { throw TranscriptionError.modelNotLoaded }
        return TranscriptionVocabulary.promptTokens(terms, tokenizer: tokenizer)
    }

    func transcribe(_ capture: CapturedAudio, vocabulary: [VocabularyTerm] = [], language: String? = "en") async throws -> TranscriptionOutcome {
        guard !inferenceInFlight, !preparationInFlight else { throw TranscriptionError.inferenceBusy }
        inferenceInFlight = true
        defer { inferenceInFlight = false }
        try Task.checkCancellation()
        guard let whisperKit else { throw TranscriptionError.modelNotLoaded }
        guard !capture.overflowed, capture.sampleRate > 0 else { throw TranscriptionError.invalidAudio }
        guard capture.duration >= 0.15, !capture.samples.isEmpty else { return .noSpeech }

        let samples = try resample(capture)
        guard !samples.isEmpty else { return .noSpeech }
        guard SpeechActivityGate.containsSpeech(in: samples) else { return .noSpeech }

        let prompt = try vocabularyPromptTokens(vocabulary)
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            temperature: 0,
            temperatureFallbackCount: 3,
            usePrefillPrompt: true,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            promptTokens: prompt.isEmpty ? nil : prompt,
            suppressBlank: true,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            noSpeechThreshold: 0.6
        )
        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
        guard let result = results.first else { throw TranscriptionError.emptyResult }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? .noSpeech : .final(text)
    }

    /// One task owns resampling, decoder calls, and phrase state for a whole
    /// dictation. Actor isolation alone would allow overlapping calls across await.
    func transcribeStream(
        from capture: AudioCaptureService,
        vocabulary: [VocabularyTerm] = [],
        language: String? = "en",
        decoderPreview: AsyncStream<DecoderPreview>.Continuation? = nil,
        progress: @Sendable (StreamingTranscriptionProgress) async -> Void = { _ in }
    ) async throws -> TranscriptionOutcome {
        guard !inferenceInFlight, !preparationInFlight else { throw TranscriptionError.inferenceBusy }
        inferenceInFlight = true
        defer { inferenceInFlight = false }
        do {
            let outcome = try await processStream(from: capture, vocabulary: vocabulary, language: language,
                                                  decoderPreview: decoderPreview, progress: progress)
            await stopPreview()
            #if VOXKEY_PERFORMANCE && !VOXKEY_RELEASE
            PerformanceRecording.shared.current?.mark(.recognitionReady)
            #endif
            return outcome
        } catch {
            await stopPreview()
            throw error
        }
    }

    private func processStream(
        from capture: AudioCaptureService, vocabulary: [VocabularyTerm], language: String?,
        decoderPreview: AsyncStream<DecoderPreview>.Continuation?,
        progress: @Sendable (StreamingTranscriptionProgress) async -> Void
    ) async throws -> TranscriptionOutcome {
        #if VOXKEY_PERFORMANCE && !VOXKEY_RELEASE
        let performance = PerformanceRecording.shared.current
        #endif
        let resampler = StreamingAudioResampler()
        let updates = await capture.audioUpdates
        var notifications = updates.makeAsyncIterator()
        var transcript = StreamingTranscript()
        var prompt: [Int]?
        var previewSchedule = ProvisionalDecodeSchedule()
        var revision = 0
        while true {
            try Task.checkCancellation()
            let input = try await capture.takePendingAudio()
            try Task.checkCancellation()
            try transcript.append(resampler.append(input.audio, isFinal: input.isFinal))
            #if VOXKEY_PERFORMANCE && !VOXKEY_RELEASE
            performance?.maximum(.maximumUncommittedAudioSeconds, Double(transcript.samples.count) / 16_000)
            if input.isFinal { performance?.add(.finalTailAudioSeconds, Double(transcript.samples.count) / 16_000) }
            #endif
            if let window = transcript.nextWindow(isFinal: input.isFinal) {
                // Cancel speculative work before any authoritative model call.
                // Core ML's current operation may finish, but no queued preview
                // or extra fallback is allowed ahead of final delivery.
                await stopPreview()
                try Task.checkCancellation()
                if !SpeechActivityGate.containsSpeech(in: window.samples) {
                    transcript.accept("", window: window, decoded: false)
                } else {
                    if prompt == nil { prompt = try vocabularyPromptTokens(vocabulary) }
                    let context = try streamingPrompt(vocabulary: prompt ?? [], precedingText: transcript.confirmedText)
                    #if DEBUG && VOXKEY_LOCAL_DIAGNOSTICS && !VOXKEY_RELEASE
                    let started = ContinuousClock.now
                    #endif
                    revision += 1
                    let observer = decoderPreview.map { continuation in
                        DecoderPreviewObserver(decodeIndex: transcript.decodeCount, revision: revision) { continuation.yield($0) }
                    }
                    let text = try await decodeStreamingWindow(window.samples, prompt: context, language: language, observer: observer)
                    try Task.checkCancellation()
                    #if DEBUG && VOXKEY_LOCAL_DIAGNOSTICS && !VOXKEY_RELEASE
                    let boundaryRepeat = TranscriptionRepetition.boundaryWordCount(previous: transcript.confirmedText, next: text)
                    logger.notice("phrase assembly index=\(transcript.decodeCount, privacy: .public) audio_start=\(transcript.consumedSamples, privacy: .public) audio_count=\(window.samples.count, privacy: .public) boundary_repeated_words=\(boundaryRepeat, privacy: .public)")
                    #endif
                    transcript.accept(text, window: window)
                    #if DEBUG && VOXKEY_LOCAL_DIAGNOSTICS && !VOXKEY_RELEASE
                    let seconds = started.duration(to: .now).components
                    let elapsed = Double(seconds.seconds) + Double(seconds.attoseconds) / 1e18
                    logger.debug("partial decode seconds=\(elapsed, privacy: .public) audio_seconds=\(Double(window.samples.count) / 16000, privacy: .public)")
                    #endif
                }
                await progress(StreamingTranscriptionProgress(
                    decodeCount: transcript.decodeCount,
                    confirmedAudioSeconds: Double(transcript.consumedSamples) / 16_000,
                    bufferedAudioSeconds: Double(transcript.samples.count) / 16_000,
                    confirmedText: transcript.confirmedText
                ))
                if input.isFinal { return transcript.outcome }
                // Read capture's latest state between phrases. A release during
                // inference should finalize the tail before scheduling more cuts.
                continue
            }
            if input.isFinal { return transcript.outcome }
            if let decoderPreview,
               let samples = previewSchedule.nextSamples(in: transcript, decoderAvailable: !previewRunning) {
                do {
                    if prompt == nil { prompt = try vocabularyPromptTokens(vocabulary) }
                    let context = try streamingPrompt(vocabulary: prompt ?? [], precedingText: transcript.confirmedText)
                    revision += 1
                    startPreview(samples, prompt: context, language: language, decodeIndex: transcript.decodeCount,
                                 revision: revision, continuation: decoderPreview)
                } catch {
                    // Prompt preparation is speculative too. Its failure must
                    // not end capture; authoritative decoding still reports errors.
                }
            }
            _ = await notifications.next()
        }
    }

    private func startPreview(_ samples: [Float], prompt: [Int], language: String?, decodeIndex: Int,
                              revision: Int, continuation: AsyncStream<DecoderPreview>.Continuation) {
        let observer = DecoderPreviewObserver(decodeIndex: decodeIndex, revision: revision) { continuation.yield($0) }
        previewObserver = observer
        previewRunning = true
        previewTask = Task(priority: .utility) {
            defer { previewRunning = false }
            do {
                try Task.checkCancellation()
                let text = try await decodeStreamingWindow(samples, prompt: prompt, language: language,
                                                          observer: observer, previewOnly: true)
                try Task.checkCancellation()
                continuation.yield(DecoderPreview(decodeIndex: decodeIndex, windowIndex: 0, tokens: [],
                                                   revision: revision, text: text))
            } catch {
                // Speculation is disposable. Its failure must not fail dictation.
            }
        }
    }

    private func stopPreview() async {
        #if VOXKEY_PERFORMANCE && !VOXKEY_RELEASE
        let performance = previewTask == nil ? nil : PerformanceRecording.shared.current
        let started = ContinuousClock.now
        defer { performance?.add(.previewCancellationWaitMS, PerformanceSession.milliseconds(since: started)) }
        #endif
        previewObserver?.cancelDecoding()
        previewTask?.cancel()
        await previewTask?.value
        previewTask = nil
        previewObserver = nil
    }

    private func streamingPrompt(vocabulary: [Int], precedingText: String) throws -> [Int] {
        guard let tokenizer = whisperKit?.tokenizer else { throw TranscriptionError.modelNotLoaded }
        return TranscriptionVocabulary.streamingPrompt(vocabulary: vocabulary, precedingText: precedingText, tokenizer: tokenizer)
    }

    /// Token-to-text presentation only; never feeds text back into recognition.
    func textForPreview(_ preview: DecoderPreview) -> String {
        preview.text ?? textForPreview(preview.tokens)
    }

    func textForPreview(_ tokens: [Int]) -> String {
        guard let tokenizer = whisperKit?.tokenizer else { return "" }
        let generated = DecoderPreviewObserver.generatedTokens(tokens,
            startOfTranscript: tokenizer.specialTokens.startOfTranscriptToken,
            specialTokenBegin: tokenizer.specialTokens.specialTokenBegin)
        return tokenizer.decode(tokens: generated).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodeStreamingWindow(_ samples: [Float], prompt: [Int], language: String?, observer: DecoderPreviewObserver? = nil, previewOnly: Bool = false) async throws -> String {
        #if VOXKEY_PERFORMANCE && !VOXKEY_RELEASE
        let performance = PerformanceRecording.shared.current
        let performanceStarted = ContinuousClock.now
        var completed = false
        performance?.add(previewOnly ? .previewDecodes : .authoritativeDecodes)
        performance?.add(previewOnly ? .previewAudioSeconds : .authoritativeAudioSeconds, Double(samples.count) / 16_000)
        defer {
            performance?.add(previewOnly ? .previewDecodeMS : .authoritativeDecodeMS, PerformanceSession.milliseconds(since: performanceStarted))
            if previewOnly { performance?.add(completed ? .previewCompleted : .previewInterrupted) }
            else if completed, performance?.released == false { performance?.add(.authoritativeDecodesBeforeRelease) }
        }
        #endif
        defer { observer?.close() }
        guard let whisperKit else { throw TranscriptionError.modelNotLoaded }
        var options = DecodingOptions(
            verbose: false, task: .transcribe, language: language, temperature: 0,
            temperatureFallbackCount: 3, usePrefillPrompt: true,
            detectLanguage: language == nil,
            skipSpecialTokens: true, withoutTimestamps: true,
            windowClipTime: 0,
            promptTokens: prompt.isEmpty ? nil : prompt,
            suppressBlank: true, compressionRatioThreshold: 2.4, logProbThreshold: -1,
            noSpeechThreshold: 0.6, concurrentWorkerCount: 1, chunkingStrategy: ChunkingStrategy.none
        )
        if previewOnly {
            options.temperatureFallbackCount = 0
            options.sampleLength = 128
        }
        let callback: TranscriptionCallback?
        if let observer { callback = { progress in observer.observe(progress) } }
        else { callback = nil }
        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options, callback: callback)
        guard !results.isEmpty else { throw TranscriptionError.emptyResult }
        #if VOXKEY_PERFORMANCE && !VOXKEY_RELEASE
        completed = !Task.isCancelled
        #endif
        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        #if DEBUG && VOXKEY_LOCAL_DIAGNOSTICS && !VOXKEY_RELEASE
        let segments = results.flatMap(\.segments)
        let repeatedWords = TranscriptionRepetition.adjacentWordCount(in: text)
        let segmentRepeatedWords = segments.map { TranscriptionRepetition.adjacentWordCount(in: $0.text) }.max() ?? 0
        let timestampTokens = segments.flatMap(\.tokens).filter { $0 >= (whisperKit.tokenizer?.specialTokens.timeTokenBegin ?? Int.max) }.count
        logger.notice("decode result repeated_words=\(repeatedWords, privacy: .public) segment_repeated_words=\(segmentRepeatedWords, privacy: .public) segments=\(segments.count, privacy: .public) timestamp_tokens=\(timestampTokens, privacy: .public) prompt_tokens=\(prompt.count, privacy: .public)")
        #endif
        return text
    }

    private func resample(_ capture: CapturedAudio) throws -> [Float] {
        if abs(capture.sampleRate - Self.targetSampleRate) < 1 {
            return capture.samples
        }

        guard let inputFormat = AVAudioFormat(
            standardFormatWithSampleRate: capture.sampleRate,
            channels: 1
        ), let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(capture.samples.count)
        ), let channel = inputBuffer.floatChannelData?[0] else {
            throw TranscriptionError.resamplingFailed
        }

        inputBuffer.frameLength = AVAudioFrameCount(capture.samples.count)
        capture.samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: source.count)
        }

        guard let converted = AudioProcessor.resampleAudio(
            fromBuffer: inputBuffer,
            toSampleRate: Self.targetSampleRate,
            channelCount: 1
        ), let convertedChannel = converted.floatChannelData?[0] else {
            throw TranscriptionError.resamplingFailed
        }

        return Array(UnsafeBufferPointer(start: convertedChannel, count: Int(converted.frameLength)))
    }
}

struct StreamingTranscriptionProgress: Sendable {
    let decodeCount: Int
    let confirmedAudioSeconds: Double
    let bufferedAudioSeconds: Double
    /// Committed phrases only. Never include this text in diagnostics.
    let confirmedText: String
}

enum TranscriptionVocabulary {
    // WhisperKit 0.15 retains only this many prompt tokens. Select before passing
    // them in so its suffix truncation cannot discard the user's highest priorities.
    static let tokenBudget = Constants.maxTokenContext / 2 - 1

    static func streamingPrompt(vocabulary: [Int], precedingText: String, tokenizer: any WhisperTokenizer) -> [Int] {
        let budget = max(0, min(16, tokenBudget - vocabulary.count))
        guard budget > 0, !precedingText.isEmpty else { return vocabulary }
        let context = tokenizer.encode(text: " " + precedingText.suffix(512))
            .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        return vocabulary + context.suffix(budget)
    }

    static func promptTokens(_ terms: [VocabularyTerm], tokenizer: any WhisperTokenizer) -> [Int] {
        var hints: [String] = []
        var tokens: [Int] = []
        for term in terms {
            let candidate = hints + [term.recognitionHint]
            let encoded = tokenizer.encode(text: " " + candidate.joined(separator: ", "))
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            guard encoded.count <= tokenBudget else { break }
            hints = candidate
            tokens = encoded
        }
        return tokens
    }
}
