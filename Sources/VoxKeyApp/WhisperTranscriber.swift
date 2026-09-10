@preconcurrency import AVFoundation
import Foundation
import OSLog
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
    private var inferenceInFlight = false
    private let logger = Logger(subsystem: "com.rodrigouroz.VoxKey", category: "transcription")
    private(set) var selectedModel = defaultModel

    // Let Core ML use all available processors, including
    // the GPU: local end-to-end measurements substantially favor it on M5 Pro.
    init(computeOptions: ModelComputeOptions? = ModelComputeOptions(
        audioEncoderCompute: .all, textDecoderCompute: .all
    )) {
        self.computeOptions = computeOptions
    }

    func prepare(
        model: String = defaultModel,
        download: Bool = true,
        progress: @escaping @Sendable (ModelPreparationPhase) -> Void = { _ in }
    ) async throws {
        guard !inferenceInFlight else { throw TranscriptionError.inferenceBusy }
        if whisperKit != nil, selectedModel == model { return }

        let downloadBase = try modelDownloadBase()
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
            modelFolder = localModelFolder(model: model, downloadBase: downloadBase)
            guard isCompleteModel(at: modelFolder) else {
                throw TranscriptionError.modelNotInstalled
            }
        }

        guard isCompleteModel(at: modelFolder) else {
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
        whisperKit = candidate
        selectedModel = model
    }

    private func modelDownloadBase() throws -> URL {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw TranscriptionError.modelNotInstalled
        }
        return documents.appending(path: "huggingface", directoryHint: .isDirectory)
    }

    private func localModelFolder(model: String, downloadBase: URL) -> URL {
        downloadBase
            .appending(path: "models/argmaxinc/whisperkit-coreml", directoryHint: .isDirectory)
            .appending(path: model, directoryHint: .isDirectory)
    }

    private func isCompleteModel(at folder: URL) -> Bool {
        let requiredPaths = [
            "MelSpectrogram.mlmodelc/weights/weight.bin",
            "AudioEncoder.mlmodelc/weights/weight.bin",
            "TextDecoder.mlmodelc/weights/weight.bin"
        ]
        return requiredPaths.allSatisfy { relativePath in
            let url = folder.appending(path: relativePath)
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else {
                return false
            }
            return values.isRegularFile == true && (values.fileSize ?? 0) > 0
        }
    }

    func vocabularyPromptTokens(_ terms: [VocabularyTerm]) throws -> [Int] {
        guard let tokenizer = whisperKit?.tokenizer else { throw TranscriptionError.modelNotLoaded }
        return TranscriptionVocabulary.promptTokens(terms, tokenizer: tokenizer)
    }

    func transcribe(_ capture: CapturedAudio, vocabulary: [VocabularyTerm] = []) async throws -> TranscriptionOutcome {
        guard !inferenceInFlight else { throw TranscriptionError.inferenceBusy }
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
            language: "en",
            temperature: 0,
            temperatureFallbackCount: 3,
            usePrefillPrompt: true,
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
        progress: @Sendable (StreamingTranscriptionProgress) -> Void = { _ in }
    ) async throws -> TranscriptionOutcome {
        guard !inferenceInFlight else { throw TranscriptionError.inferenceBusy }
        inferenceInFlight = true
        defer { inferenceInFlight = false }
        let resampler = StreamingAudioResampler()
        let updates = await capture.audioUpdates
        var notifications = updates.makeAsyncIterator()
        var transcript = StreamingTranscript()
        var prompt: [Int]?
        while true {
            try Task.checkCancellation()
            let input = try await capture.takePendingAudio()
            try Task.checkCancellation()
            try transcript.append(resampler.append(input.audio, isFinal: input.isFinal))
            if let window = transcript.nextWindow(isFinal: input.isFinal) {
                try Task.checkCancellation()
                if !SpeechActivityGate.containsSpeech(in: window.samples) {
                    transcript.accept("", window: window, decoded: false)
                } else {
                    if prompt == nil { prompt = try vocabularyPromptTokens(vocabulary) }
                    let context = try streamingPrompt(vocabulary: prompt ?? [], precedingText: transcript.confirmedText)
                    let started = ContinuousClock.now
                    let text = try await decodeStreamingWindow(window.samples, prompt: context)
                    try Task.checkCancellation()
                    let boundaryRepeat = TranscriptionRepetition.boundaryWordCount(previous: transcript.confirmedText, next: text)
                    logger.notice("phrase assembly index=\(transcript.decodeCount, privacy: .public) audio_start=\(transcript.consumedSamples, privacy: .public) audio_count=\(window.samples.count, privacy: .public) boundary_repeated_words=\(boundaryRepeat, privacy: .public)")
                    transcript.accept(text, window: window)
                    let seconds = started.duration(to: .now).components
                    let elapsed = Double(seconds.seconds) + Double(seconds.attoseconds) / 1e18
                    logger.debug("partial decode seconds=\(elapsed, privacy: .public) audio_seconds=\(Double(window.samples.count) / 16000, privacy: .public)")
                }
                progress(StreamingTranscriptionProgress(
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
            _ = await notifications.next()
        }
    }

    private func streamingPrompt(vocabulary: [Int], precedingText: String) throws -> [Int] {
        guard let tokenizer = whisperKit?.tokenizer else { throw TranscriptionError.modelNotLoaded }
        return TranscriptionVocabulary.streamingPrompt(vocabulary: vocabulary, precedingText: precedingText, tokenizer: tokenizer)
    }

    private func decodeStreamingWindow(_ samples: [Float], prompt: [Int]) async throws -> String {
        guard let whisperKit else { throw TranscriptionError.modelNotLoaded }
        let options = DecodingOptions(
            verbose: false, task: .transcribe, language: "en", temperature: 0,
            temperatureFallbackCount: 3, usePrefillPrompt: true,
            skipSpecialTokens: true, withoutTimestamps: true,
            windowClipTime: 0,
            promptTokens: prompt.isEmpty ? nil : prompt,
            suppressBlank: true, compressionRatioThreshold: 2.4, logProbThreshold: -1,
            noSpeechThreshold: 0.6, concurrentWorkerCount: 1, chunkingStrategy: ChunkingStrategy.none
        )
        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
        guard !results.isEmpty else { throw TranscriptionError.emptyResult }
        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = results.flatMap(\.segments)
        let repeatedWords = TranscriptionRepetition.adjacentWordCount(in: text)
        let segmentRepeatedWords = segments.map { TranscriptionRepetition.adjacentWordCount(in: $0.text) }.max() ?? 0
        let timestampTokens = segments.flatMap(\.tokens).filter { $0 >= (whisperKit.tokenizer?.specialTokens.timeTokenBegin ?? Int.max) }.count
        logger.notice("decode result repeated_words=\(repeatedWords, privacy: .public) segment_repeated_words=\(segmentRepeatedWords, privacy: .public) segments=\(segments.count, privacy: .public) timestamp_tokens=\(timestampTokens, privacy: .public) prompt_tokens=\(prompt.count, privacy: .public)")
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
