@preconcurrency import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import VoxKeyApp
import VoxKeyCore

@Test(arguments: [2.2, 4.2, 6.2])
func unfinishedDictationDoesNotQueueRedundantDecodesBeforeRelease(_ seconds: Double) throws {
    var transcript = StreamingTranscript()
    let audio = Array(repeating: Float(0.1), count: Int(seconds * 16_000))
    for start in stride(from: 0, to: audio.count, by: 1_600) {
        try transcript.append(Array(audio[start..<min(start + 1_600, audio.count)]))
        let waitsForSpeechBoundary = transcript.nextWindow(isFinal: false) == nil
        #expect(waitsForSpeechBoundary)
    }
    let final = try requireWindow(&transcript, isFinal: true)
    let preservesAudio = final.samples == audio
    #expect(preservesAudio)
    transcript.accept("Keep the entire sentence.", window: final)
    #expect(transcript.outcome == .final("Keep the entire sentence."))
    #expect(transcript.decodeCount == 1)
}

@Test
func releaseDecodesTheEntireRemainingTailIncludingPausesOnce() throws {
    var transcript = StreamingTranscript()
    let audio = Array(repeating: Float(0.1), count: 32_000)
        + Array(repeating: 0, count: 4_800) + Array(repeating: 0.1, count: 8_000)
    try transcript.append(audio)
    let final = try requireWindow(&transcript, isFinal: true)
    let preservesAudio = final.samples == audio
    #expect(preservesAudio)
    transcript.accept("Before the pause. After the pause.", window: final)
    #expect(transcript.samples.isEmpty)
    #expect(transcript.decodeCount == 1)
}

@Test
func completedPhrasesSurviveTheFinalTailAndIntentionalRepeatedWords() throws {
    var transcript = StreamingTranscript()
    let samples = Array(repeating: Float(0.1), count: 2 * 16_000) + Array(repeating: 0, count: 3_200)
    try transcript.append(samples)
    let phrase = try requireWindow(&transcript, isFinal: false)
    #expect(phrase.samples.count == 33_600)
    transcript.accept("This is very very useful.", window: phrase)
    try transcript.append(Array(repeating: 0.1, count: 2 * 16_000))
    let pending = transcript.nextWindow(isFinal: false)
    #expect(pending == nil)
    try transcript.append(Array(repeating: 0.1, count: 800))
    let final = try requireWindow(&transcript, isFinal: true)
    transcript.accept("Very useful tomorrow.", window: final)
    #expect(transcript.outcome == .final("This is very very useful. Very useful tomorrow."))
    #expect(transcript.consumedSamples == samples.count + 32_800)
}

@Test
func releaseFlushesAudioBelowTheMinimumPhraseLength() throws {
    var transcript = StreamingTranscript()
    try transcript.append(Array(repeating: 0.1, count: 8_000))
    let pending = transcript.nextWindow(isFinal: false)
    #expect(pending == nil)
    let final = try requireWindow(&transcript, isFinal: true)
    #expect(final.samples.count == 8_000)
    transcript.accept("Hello.", window: final)
    #expect(transcript.outcome == .final("Hello."))
}

@Test
func shortQuietGapsCannotCutAnUnfinishedWord() throws {
    var transcript = StreamingTranscript()
    try transcript.append(Array(repeating: 0.1, count: 32_000) + Array(repeating: 0, count: 2_880) +
                          Array(repeating: 0.1, count: 8_000))
    let pending = transcript.nextWindow(isFinal: false)
    #expect(pending == nil)
    #expect(transcript.samples.count == 42_880)
}

@Test
func tenMinuteStreamingReleasesCompletedAudioWithoutLosingPhrases() throws {
    var transcript = StreamingTranscript()
    let phraseAudio = Array(repeating: Float(0.1), count: 32_000) + Array(repeating: 0, count: 4_800)
    for _ in 0..<260 {
        try transcript.append(phraseAudio)
        let phrase = try requireWindow(&transcript, isFinal: false)
        transcript.accept("Hello.", window: phrase)
    }
    #expect(transcript.consumedSamples > 590 * 16_000)
    #expect(transcript.samples.count < 4 * 16_000)
    #expect(transcript.confirmedText.split(separator: " ").count == 260)
}

@Test
func uninterruptedSpeechIsRetainedInsteadOfGuessingATimestampCut() throws {
    var transcript = StreamingTranscript()
    try transcript.append(Array(repeating: 0.1, count: 40 * 16_000))
    let pending = transcript.nextWindow(isFinal: false)
    #expect(pending == nil)
    #expect(transcript.consumedSamples == 0)
    #expect(transcript.samples.count == 40 * 16_000)
    #expect(throws: TranscriptionError.self) {
        try transcript.append(Array(repeating: 0, count: StreamingTranscript.maximumBufferedSamples))
    }
}

@Test(arguments: [16_000, 44_100, 48_000])
func incrementalResamplingMatchesContinuousAudioAndFlushesTheTail(_ sampleRate: Int) throws {
    let input = (0..<(sampleRate * 2 + 137)).map {
        Float(sin(2 * .pi * 317 * Double($0) / Double(sampleRate))) * 0.1
    }
    let continuous = StreamingAudioResampler()
    let expected = try continuous.append(.init(samples: input, sampleRate: Double(sampleRate), overflowed: false), isFinal: true)
    let incremental = StreamingAudioResampler()
    var actual: [Float] = []
    for start in stride(from: 0, to: input.count, by: 997) {
        actual += try incremental.append(.init(samples: Array(input[start..<min(input.count, start + 997)]),
                                               sampleRate: Double(sampleRate), overflowed: false), isFinal: false)
    }
    actual += try incremental.append(.init(samples: [], sampleRate: Double(sampleRate), overflowed: false), isFinal: true)
    #expect(actual.count == expected.count)
    #expect(zip(actual, expected).allSatisfy { abs($0 - $1) < 0.000_01 })
    #expect(abs(Double(actual.count) - Double(input.count) * 16_000 / Double(sampleRate)) < 32)
}

@Test
func captureTransfersEverySampleOnceIncludingTheFinalShortTail() async throws {
    let input = SyntheticAudioInput()
    let capture = AudioCaptureService(makeInput: { _ in input })
    try await capture.start()
    input.emit(Array(repeating: 0.08, count: 4_800))
    let first = try await capture.takePendingAudio()
    #expect(first.audio.samples.count == 4_800)
    #expect(!first.isFinal)
    #expect(await capture.speechStartStatus() == .speech)
    input.emit(Array(repeating: 0.04, count: 137))
    try await capture.finish()
    let tail = try await capture.takePendingAudio()
    #expect(tail.isFinal)
    #expect(tail.audio.samples == Array(repeating: Float(0.04), count: 137))
    #expect(try await capture.takePendingAudio().audio.samples.isEmpty)
}

@Test
func captureBackpressureFailsExplicitlyAndCancellationResetsIt() async throws {
    let input = SyntheticAudioInput()
    let capture = AudioCaptureService(makeInput: { _ in input })
    try await capture.start()
    // Pump the hardware ring without consuming the accumulated pending queue.
    for _ in 0..<31 {
        input.emit(Array(repeating: 0, count: 16_000))
        _ = await capture.speechStartStatus()
    }
    await #expect(throws: AudioCaptureError.self) { try await capture.takePendingAudio() }
    await capture.cancel()
    try await capture.start()
    input.emit([0.1, 0.2])
    let fresh = try await capture.stop()
    #expect(fresh.samples == [0.1, 0.2])
}

@Test
func cancellingAnIdleStreamingWorkerAllowsTheNextDictation() async throws {
    let input = SyntheticAudioInput()
    let capture = AudioCaptureService(makeInput: { _ in input })
    let transcriber = WhisperTranscriber()
    try await capture.start()
    let worker = Task { try await transcriber.transcribeStream(from: capture) }
    worker.cancel()
    await capture.cancel()
    await #expect(throws: CancellationError.self) { try await worker.value }
    try await capture.start()
    let next = Task { try await transcriber.transcribeStream(from: capture) }
    try await capture.finish()
    #expect(try await next.value == .noSpeech)
}

/// Opt-in real-model test. Input must be public/synthetic speech, never a user's recording.
@Test(.enabled(if: ProcessInfo.processInfo.environment["VOXKEY_SHORT_TEST_AUDIO"] != nil))
func installedWhisperModelFinalizesAShortSentenceWithOneDecode() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["VOXKEY_SHORT_TEST_AUDIO"])
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let rate = file.processingFormat.sampleRate
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let samples = Array(UnsafeBufferPointer(start: try #require(buffer.floatChannelData?[0]), count: Int(buffer.frameLength)))
    // The former two-second speculative pass must be crossed by this fixture.
    try #require((2...3).contains(Double(samples.count) / rate))
    let vocabulary = [VocabularyTerm(canonical: "Quasar Ledger")]
    let transcriber = WhisperTranscriber()
    try await transcriber.prepare(download: false)
    let input = SyntheticAudioInput(sampleRate: rate)
    let capture = AudioCaptureService(makeInput: { _ in input })
    let passes = Mutex(0)
    try await capture.start()
    let worker = Task {
        try await transcriber.transcribeStream(from: capture, vocabulary: vocabulary) { update in
            passes.withLock { $0 = update.decodeCount }
        }
    }
    let started = ContinuousClock.now
    let chunkSize = Int(rate / 10)
    for start in stride(from: 0, to: samples.count, by: chunkSize) {
        let end = min(start + chunkSize, samples.count)
        input.emit(Array(samples[start..<end]))
        try await Task.sleep(until: started.advanced(by: .seconds(Double(end) / rate)), clock: .continuous)
    }
    try await capture.finish()
    let streamed = try await worker.value
    let baseline = try await transcriber.transcribe(.init(samples: samples, sampleRate: rate, overflowed: false), vocabulary: vocabulary)
    #expect(passes.withLock { $0 } == 1)
    guard case let .final(text) = streamed, case let .final(batchText) = baseline else {
        Issue.record("Both paths must return the short spoken sentence")
        return
    }
    #expect(transcriptionWordDifferences(text, "Please send me the notes after the meeting.") == 0)
    #expect(transcriptionWordDifferences(text, batchText) == 0)
}

/// Opt-in real-model test. Input must be public/synthetic speech, never a user's recording.
@Test(.enabled(if: ProcessInfo.processInfo.environment["VOXKEY_STREAMING_TEST_AUDIO"] != nil))
func installedWhisperModelStreamsSpeechAndReconcilesItsFinalWord() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["VOXKEY_STREAMING_TEST_AUDIO"])
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let original = Array(UnsafeBufferPointer(start: try #require(buffer.floatChannelData?[0]), count: Int(buffer.frameLength)))
    let repetitions = max(1, min(6, Int(ProcessInfo.processInfo.environment["VOXKEY_STREAMING_TEST_REPETITIONS"] ?? "1") ?? 1))
    let samples = Array(repeating: original, count: repetitions).flatMap { $0 }
    let sampleRate = file.processingFormat.sampleRate
    let transcriber = WhisperTranscriber()
    try await transcriber.prepare(download: false)
    let input = SyntheticAudioInput(sampleRate: sampleRate)
    let capture = AudioCaptureService(makeInput: { _ in input })
    let progress = Mutex<[StreamingTranscriptionProgress]>([])
    try await capture.start()
    let worker = Task {
        try await transcriber.transcribeStream(from: capture, vocabulary: [VocabularyTerm(canonical: "Quasar Ledger")]) {
            update in progress.withLock { $0.append(update) }
        }
    }
    let started = ContinuousClock.now
    let chunkSize = Int(sampleRate / 10)
    for start in stride(from: 0, to: samples.count, by: chunkSize) {
        input.emit(Array(samples[start..<min(start + chunkSize, samples.count)]))
        try await Task.sleep(until: started.advanced(by: .seconds(Double(min(start + chunkSize, samples.count)) / sampleRate)), clock: .continuous)
    }
    let beforeRelease = progress.withLock { $0.last }
    let released = ContinuousClock.now
    try await capture.finish()
    let result = try await worker.value
    let finalization = released.duration(to: .now)
    let baselineStarted = ContinuousClock.now
    let baseline = try await transcriber.transcribe(.init(samples: samples, sampleRate: sampleRate, overflowed: false),
                                                   vocabulary: [VocabularyTerm(canonical: "Quasar Ledger")])
    let batchDuration = baselineStarted.duration(to: .now)
    guard case let .final(text) = result, case let .final(baselineText) = baseline else {
        Issue.record("The installed model did not produce both streaming and batch text")
        return
    }
    let differences = transcriptionWordDifferences(text, baselineText)
    let script = "Please update the Quasar Ledger before the next meeting. The first section explains how the new recording system works. We should preserve every word, including repeated words like very very useful. The second section covers cancellation and the final sentence. Please keep the number forty two in the notes. At the end of this dictation, send nothing automatically. The final word is telescope."
    let reference = Array(repeating: script, count: repetitions).joined(separator: " ")
    let streamingErrors = transcriptionWordDifferences(text, reference)
    let batchErrors = transcriptionWordDifferences(baselineText, reference)
    #expect(streamingErrors <= batchErrors, "Streaming must preserve the spoken script at least as well as batch: \(text)")
    #expect((beforeRelease?.decodeCount ?? 0) >= 2)
    #expect((beforeRelease?.confirmedAudioSeconds ?? 0) > 0)
    #expect(text.lowercased().contains("quasar ledger"))
    #expect(text.lowercased().contains("very very"))
    #expect(text.lowercased().contains("telescope"))
    #expect(text.lowercased().components(separatedBy: "quasar ledger").count == repetitions + 1)
    print("Synthetic streaming benchmark: duration=\(Double(samples.count) / sampleRate)s, differences=\(differences), streaming_errors=\(streamingErrors), batch_errors=\(batchErrors), release=\(finalization), batch=\(batchDuration), partials=\(beforeRelease?.decodeCount ?? 0), tail=\(beforeRelease?.bufferedAudioSeconds ?? 0)s")
}

private func transcriptionWordDifferences(_ actual: String, _ expected: String) -> Int {
    let actual = actual.lowercased().replacingOccurrences(of: "forty two", with: "42").split { !$0.isLetter && !$0.isNumber }.map(String.init)
    let expected = expected.lowercased().replacingOccurrences(of: "forty two", with: "42").split { !$0.isLetter && !$0.isNumber }.map(String.init)
    var previous = Array(0...expected.count)
    for (index, word) in actual.enumerated() {
        var row = [index + 1]
        for (column, reference) in expected.enumerated() {
            row.append(min(row[column] + 1, previous[column + 1] + 1,
                           previous[column] + (word == reference ? 0 : 1)))
        }
        previous = row
    }
    return previous.last ?? 0
}

private func requireWindow(_ transcript: inout StreamingTranscript, isFinal: Bool) throws -> StreamingDecodeWindow {
    let candidate = transcript.nextWindow(isFinal: isFinal)
    return try #require(candidate)
}

@Test
func aSilentFinalTailPreservesCompletedPhrases() throws {
    var transcript = StreamingTranscript()
    try transcript.append(Array(repeating: 0.1, count: 32_000) + Array(repeating: 0, count: 3_200))
    let phrase = try requireWindow(&transcript, isFinal: false)
    transcript.accept("Keep these words", window: phrase)
    let tail = try requireWindow(&transcript, isFinal: true)
    #expect(tail.samples.allSatisfy { $0 == 0 })
    transcript.accept("", window: tail, decoded: false)
    #expect(transcript.outcome == .final("Keep these words"))
    #expect(transcript.samples.isEmpty)
    #expect(transcript.decodeCount == 1)
}

@MainActor
@Test(arguments: [false, true])
func teardownRacingCaptureStartupCannotLeaveTheMicrophoneRunning(_ terminating: Bool) async throws {
    for _ in 0..<20 {
        let input = SyntheticAudioInput()
        let capture = AudioCaptureService(makeInput: { _ in input })
        let sessionID = DictationSessionID()
        let coordinator = SessionCoordinator(audioCapture: capture, accessibility: DesktopFixture().service,
                                             initialState: .init(phase: .arming(sessionID)))
        async let starting: Void = coordinator.startCapture(sessionID: sessionID)
        if terminating {
            await coordinator.prepareForTermination()
        } else {
            await coordinator.cancel(expectedSessionID: sessionID)
        }
        await starting
        #expect(!input.isRunning)
        #expect(try await capture.stop().samples.isEmpty)
        #expect(await coordinator.lastResult() == nil)
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VOXKEY_STREAMING_TEST_AUDIO"] != nil))
func installedWhisperModelCancelsAfterPartialSpeechWithoutLeakingIntoTheNextSession() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["VOXKEY_STREAMING_TEST_AUDIO"])
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let sampleRate = file.processingFormat.sampleRate
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(sampleRate * 3)))
    try file.read(into: buffer)
    let samples = Array(UnsafeBufferPointer(start: try #require(buffer.floatChannelData?[0]), count: Int(buffer.frameLength)))
    let transcriber = WhisperTranscriber()
    try await transcriber.prepare(download: false)
    let input = SyntheticAudioInput(sampleRate: sampleRate)
    let capture = AudioCaptureService(makeInput: { _ in input })
    let completedPasses = Mutex(0)
    try await capture.start()
    let worker = Task {
        try await transcriber.transcribeStream(from: capture) { progress in
            completedPasses.withLock { $0 = progress.decodeCount }
        }
    }
    // End a real acoustic phrase so cancellation follows useful partial work.
    input.emit(samples + Array(repeating: 0, count: Int(sampleRate * 0.2)))
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while completedPasses.withLock({ $0 }) == 0, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(completedPasses.withLock { $0 } > 0)
    worker.cancel()
    await capture.cancel()
    await #expect(throws: CancellationError.self) { try await worker.value }
    #expect(!input.isRunning)
    try await capture.start()
    let next = Task { try await transcriber.transcribeStream(from: capture) }
    input.emit(Array(repeating: 0, count: Int(sampleRate)))
    try await capture.finish()
    #expect(try await next.value == .noSpeech)
}

@MainActor
@Test
func duplicateCaptureStartupKeepsOneActiveSession() async {
    for _ in 0..<20 {
        let input = SyntheticAudioInput()
        let capture = AudioCaptureService(makeInput: { _ in input })
        let sessionID = DictationSessionID()
        let desktop = DesktopFixture()
        let coordinator = SessionCoordinator(audioCapture: capture, accessibility: desktop.service,
                                             initialState: .init(phase: .arming(sessionID)))
        async let first: Void = coordinator.startCapture(sessionID: sessionID)
        async let second: Void = coordinator.startCapture(sessionID: sessionID)
        await first
        await second
        #expect(await coordinator.currentSnapshot().phase == .capturing(sessionID))
        #expect(input.isRunning)
        await coordinator.cancel(expectedSessionID: sessionID)
        #expect(!input.isRunning)
    }
}
