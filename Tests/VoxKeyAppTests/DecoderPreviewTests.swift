import AppKit
import AVFoundation
import Foundation
import Synchronization
import Testing
@preconcurrency import WhisperKit
@testable import VoxKeyApp
import VoxKeyCore

@Test
func decoderPreviewOmitsVocabularyContextAndControlTokens() {
    #expect(DecoderPreviewObserver.generatedTokens([90, 11, 12, 91, 92, 93, 20, 21, 94],
        startOfTranscript: 91, specialTokenBegin: 90) == [20, 21])
    #expect(DecoderPreviewObserver.generatedTokens([90, 11, 12],
        startOfTranscript: 91, specialTokenBegin: 90).isEmpty)
    #expect(DecoderPreviewObserver.generatedTokens([91, 92, 93],
        startOfTranscript: 91, specialTokenBegin: 90).isEmpty)
}

@Test
func decoderPreviewOrdersDetachedCallbacksAndCannotStopRecognition() {
    let emitted = Mutex<[DecoderPreview]>([])
    let observer = DecoderPreviewObserver(decodeIndex: 4) { preview in emitted.withLock { $0.append(preview) } }
    func update(_ tokens: [Int], attempt: Double = 10, window: Int = 0) -> Bool? {
        var timings = TranscriptionTimings()
        timings.firstTokenTime = attempt
        var progress = TranscriptionProgress(timings: timings, text: "unused prompt text", tokens: tokens)
        progress.windowId = window
        return observer.observe(progress)
    }
    #expect(update([1, 2, 3]) == nil)
    #expect(update([1, 2]) == nil) // older token callback
    #expect(update([4], attempt: 11) == nil) // a newer fallback can revise text
    #expect(update([1, 2, 3, 4], attempt: 10) == nil) // late callback from the old attempt
    #expect(update([4, 5], attempt: 11) == nil)
    #expect(update([6], attempt: 12, window: 1) == nil)
    #expect(update([4, 5, 6], attempt: 11) == nil) // old audio window
    observer.close()
    #expect(update([6, 7], attempt: 12, window: 1) == nil)
    #expect(emitted.withLock { $0.map(\.tokens) } == [[1, 2, 3], [4], [4, 5], [6]])
    #expect(emitted.withLock { $0.allSatisfy { $0.decodeIndex == 4 } })
}

@MainActor @Test
func provisionalCaptionsYieldToCompletedPhrasesAndNeverBecomeTheResult() async {
    let id = DictationSessionID()
    let coordinator = SessionCoordinator(accessibility: DesktopFixture().service,
                                         initialState: .init(phase: .capturing(id)))
    let first = DecoderPreview(decodeIndex: 0, windowIndex: 0, tokens: [])
    await coordinator.receiveDecoderPreview(first, text: "Thursday", sessionID: id)
    #expect(await coordinator.currentSnapshot().provisionalPreview == "Thursday")
    #expect(await coordinator.currentSnapshot().transcriptPreview == nil)
    #expect(await coordinator.lastResult() == nil)
    await coordinator.receiveDecoderPreview(first, text: "Tuesday", sessionID: id)
    #expect(await coordinator.currentSnapshot().provisionalPreview == "Tuesday")
    await coordinator.receiveTranscriptionProgress(.init(decodeCount: 1, confirmedAudioSeconds: 3,
        bufferedAudioSeconds: 0, confirmedText: "Tuesday."), sessionID: id)
    #expect(await coordinator.currentSnapshot().transcriptPreview == "Tuesday.")
    #expect(await coordinator.currentSnapshot().provisionalPreview == nil)
    await coordinator.receiveDecoderPreview(first, text: "Late Thursday", sessionID: id)
    #expect(await coordinator.currentSnapshot().provisionalPreview == nil)
    let second = DecoderPreview(decodeIndex: 1, windowIndex: 0, tokens: [])
    await coordinator.receiveDecoderPreview(second, text: "New phrase", sessionID: id)
    #expect(await coordinator.currentSnapshot().provisionalPreview == "New phrase")
    await coordinator.cancel()
    await coordinator.receiveDecoderPreview(second, text: "Late phrase", sessionID: id)
    #expect(await coordinator.currentSnapshot().provisionalPreview == nil)
    #expect(await coordinator.lastResult() == nil)
}

@MainActor @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
func provisionalOverlayTextRevisesThenSettlesWithoutDuplicates(_ appearance: NSAppearance.Name) throws {
    let overlay = StatusOverlayController(animationsEnabled: false)
    let id = DictationSessionID()
    let window = try #require(overlay.window)
    window.appearance = NSAppearance(named: appearance)
    defer { window.orderOut(nil) }
    overlay.update(.init(phase: .capturing(id), lastResult: nil, provisionalPreview: "Send it on Thursday"))
    let root = try #require(window.contentView)
    let text = try #require(descendants(root).compactMap { $0 as? NSTextView }.first)
    #expect(text.string == "Send it on Thursday")
    #expect(text.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == VoxKeyDesign.Overlay.secondaryInk)
    overlay.update(.init(phase: .capturing(id), lastResult: nil, transcriptPreview: "Send it on Tuesday.",
                         provisionalPreview: "Include the updated notes"))
    #expect(text.string == "Send it on Tuesday. Include the updated notes")
    #expect(text.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == VoxKeyDesign.Overlay.ink)
    if let directory = ProcessInfo.processInfo.environment["VOXKEY_SETTINGS_PREVIEW_DIR"] {
        root.layoutSubtreeIfNeeded()
        let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(
            to: URL(fileURLWithPath: directory).appendingPathComponent("caption-provisional-\(appearance.rawValue).png"))
    }
    // Identical text must still change from provisional to completed styling.
    let final = text.string
    overlay.update(.init(phase: .finalizing(id), lastResult: nil, transcriptPreview: final))
    #expect(text.string == final)
    #expect(text.textStorage?.attribute(.foregroundColor, at: (final as NSString).length - 1, effectiveRange: nil) as? NSColor == VoxKeyDesign.Overlay.ink)
}

@MainActor
private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

/// Same audio, options, and streaming path with/without an observer. Synthetic
/// speech only; this does not capture the microphone or download a model.
@Test(.enabled(if: ProcessInfo.processInfo.environment["VOXKEY_PREVIEW_TEST_AUDIO"] != nil))
func installedModelPreviewPreservesRecognitionAndAppearsBeforeCompletion() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["VOXKEY_PREVIEW_TEST_AUDIO"])
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let samples = Array(UnsafeBufferPointer(start: try #require(buffer.floatChannelData?[0]), count: Int(buffer.frameLength)))
    let transcriber = WhisperTranscriber()
    try await transcriber.prepare(model: ProcessInfo.processInfo.environment["VOXKEY_PREVIEW_TEST_MODEL"] ?? WhisperTranscriber.defaultModel, download: false)
    let vocabulary = [VocabularyTerm(canonical: "Quasar Ledger")]
    var baseline: TranscriptionOutcome?
    var baselineDecodes = 0
    for observing in [false, true] {
        let input = SyntheticAudioInput(sampleRate: file.processingFormat.sampleRate)
        let capture = AudioCaptureService(makeInput: { _ in input })
        try await capture.start()
        input.emit(samples)
        try await capture.finish()
        let decodes = Mutex(0)
        let previews = AsyncStream.makeStream(of: DecoderPreview.self, bufferingPolicy: .bufferingNewest(1))
        let consumer = Task { @Sendable in
            var observations: [(String, ContinuousClock.Instant)] = []
            for await update in previews.stream {
                let text = await transcriber.textForPreview(update)
                observations.append((text, .now))
            }
            return observations
        }
        let result = try await transcriber.transcribeStream(from: capture, vocabulary: vocabulary,
            decoderPreview: observing ? previews.continuation : nil) { progress in decodes.withLock { $0 = progress.decodeCount } }
        let finished = ContinuousClock.now
        previews.continuation.finish()
        let updates = await consumer.value
        if !observing {
            baseline = result
            baselineDecodes = decodes.withLock { $0 }
        } else {
            #expect(result == baseline)
            #expect(decodes.withLock { $0 } == baselineDecodes)
            var firstVisible: ContinuousClock.Instant?
            for (preview, received) in updates {
                if !preview.isEmpty {
                    #expect(!preview.lowercased().contains("quasar ledger"), "Vocabulary hints are not speech")
                    firstVisible = firstVisible ?? received
                }
            }
            let first = try #require(firstVisible)
            #expect(first < finished)
            print("Passive preview: \(updates.count) updates; first generated text precedes completion by \(first.duration(to: finished)); unchanged result and decode count=\(baselineDecodes)")
        }
    }
}

/// Hold capture open with less than the two-second phrase minimum. Any visible
/// words must come from unfinished audio, not from a pause or finalization.
@Test(.enabled(if: ProcessInfo.processInfo.environment["VOXKEY_PREVIEW_TEST_AUDIO"] != nil))
func installedModelPreviewsUnfinishedSpeechBeforeRelease() async throws {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: try #require(
        ProcessInfo.processInfo.environment["VOXKEY_PREVIEW_TEST_AUDIO"])))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
        frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let samples = Array(UnsafeBufferPointer(start: try #require(buffer.floatChannelData?[0]), count: Int(buffer.frameLength)))
    let prefixCount = min(samples.count, Int(file.processingFormat.sampleRate * 1.6))
    let transcriber = WhisperTranscriber()
    try await transcriber.prepare(model: ProcessInfo.processInfo.environment["VOXKEY_PREVIEW_TEST_MODEL"] ?? WhisperTranscriber.defaultModel, download: false)
    // Warm the shared model before comparing release latency.
    _ = try await transcriber.transcribe(.init(samples: samples, sampleRate: file.processingFormat.sampleRate, overflowed: false))
    var baseline: TranscriptionOutcome?
    for observing in [false, true, true, false] {
        let input = SyntheticAudioInput(sampleRate: file.processingFormat.sampleRate)
        let capture = AudioCaptureService(makeInput: { _ in input })
        try await capture.start()
        let updates = AsyncStream.makeStream(of: DecoderPreview.self, bufferingPolicy: .bufferingNewest(1))
        let firstWord = Mutex<ContinuousClock.Instant?>(nil)
        let completedDecodes = Mutex(0)
        let consumer = Task { @Sendable in
            for await update in updates.stream {
                let text = await transcriber.textForPreview(update)
                if !text.isEmpty { firstWord.withLock { if $0 == nil { $0 = .now } } }
            }
        }
        let worker = Task { try await transcriber.transcribeStream(from: capture,
            decoderPreview: observing ? updates.continuation : nil) { progress in
            completedDecodes.withLock { $0 = progress.decodeCount }
        } }
        let started = ContinuousClock.now
        // Deliver audio at microphone speed, without generating a phrase boundary.
        let chunkSize = Int(file.processingFormat.sampleRate / 10)
        for offset in stride(from: 0, to: prefixCount, by: chunkSize) {
            input.emit(Array(samples[offset..<min(offset + chunkSize, prefixCount)]))
            try await Task.sleep(for: .milliseconds(100))
        }
        if observing {
            let deadline = started.advanced(by: .seconds(3))
            while firstWord.withLock({ $0 == nil }), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(firstWord.withLock { $0 != nil }, "Unfinished speech should produce visible words before release")
            #expect(completedDecodes.withLock { $0 } == 0, "Preview must not commit an acoustic phrase")
        }
        input.emit(Array(samples.dropFirst(prefixCount)))
        let released = ContinuousClock.now
        try await capture.finish()
        let result = try await worker.value
        let finished = ContinuousClock.now
        updates.continuation.finish()
        await consumer.value
        if observing {
            #expect(result == baseline, "Preview must not change final recognition")
            if let first = firstWord.withLock({ $0 }) {
                print("Unfinished preview: first words after \(started.duration(to: first)); release to result \(released.duration(to: finished))")
            }
        } else {
            baseline = result
            print("No preview: release to result \(released.duration(to: finished))")
        }
    }
}

@Test
func provisionalDecodeCopiesBoundedAudioWithoutRetiringOrCommittingIt() throws {
    var transcript = StreamingTranscript()
    let audio = (0..<(40 * 16_000)).map { Float(sin(Double($0) * 0.12)) * 0.1 }
    try transcript.append(audio)
    var schedule = ProvisionalDecodeSchedule()
    let now = ContinuousClock.now
    #expect(schedule.nextSamples(in: transcript, now: now) == Array(audio.suffix(8 * 16_000)))
    #expect(schedule.nextSamples(in: transcript, now: now.advanced(by: .seconds(2))) == nil)
    #expect(transcript.samples == audio)
    #expect(transcript.consumedSamples == 0)
    #expect(transcript.decodeCount == 0)
    #expect(transcript.confirmedText.isEmpty)
    #expect(transcript.nextWindow(isFinal: false) == nil)
    #expect(transcript.nextWindow(isFinal: true)?.samples == audio)
}

@Test
func provisionalDecodeRequiresSpeechAndThrottlesNewAudio() throws {
    var transcript = StreamingTranscript()
    var schedule = ProvisionalDecodeSchedule()
    let now = ContinuousClock.now
    try transcript.append(Array(repeating: 0, count: 16_000))
    #expect(schedule.nextSamples(in: transcript, now: now) == nil)
    try transcript.append(Array(repeating: 0.1, count: 8_000))
    #expect(schedule.nextSamples(in: transcript, now: now.advanced(by: .milliseconds(300))) == nil)
    #expect(schedule.nextSamples(in: transcript, now: now.advanced(by: .milliseconds(700))) != nil)
    try transcript.append(Array(repeating: 0.1, count: 8_000))
    #expect(schedule.nextSamples(in: transcript, now: now.advanced(by: .milliseconds(900))) == nil)
    #expect(schedule.nextSamples(in: transcript, now: now.advanced(by: .milliseconds(1_400))) != nil)
}

@Test
func cancelledSpeculationStopsTheDecoderAndSuppressesFurtherWords() {
    let emitted = Mutex<[DecoderPreview]>([])
    let observer = DecoderPreviewObserver(decodeIndex: 0) { update in emitted.withLock { $0.append(update) } }
    observer.cancelDecoding()
    #expect(observer.observe(.init(timings: TranscriptionTimings(), text: "Late", tokens: [1])) == false)
    #expect(emitted.withLock { $0.isEmpty })
}

@MainActor @Test
func newerPreviewReplacesItsEntireHypothesisAndRejectsOlderRevisions() async {
    let id = DictationSessionID()
    let coordinator = SessionCoordinator(accessibility: DesktopFixture().service,
                                         initialState: .init(phase: .capturing(id)))
    await coordinator.receiveDecoderPreview(.init(decodeIndex: 0, windowIndex: 0, tokens: [], revision: 1),
                                            text: "First window", sessionID: id)
    await coordinator.receiveDecoderPreview(.init(decodeIndex: 0, windowIndex: 1, tokens: [], revision: 1),
                                            text: "second window", sessionID: id)
    #expect(await coordinator.currentSnapshot().provisionalPreview == "First window second window")
    await coordinator.receiveDecoderPreview(.init(decodeIndex: 0, windowIndex: 0, tokens: [], revision: 2),
                                            text: "Revised recent speech", sessionID: id)
    await coordinator.receiveDecoderPreview(.init(decodeIndex: 0, windowIndex: 2, tokens: [], revision: 1),
                                            text: "Stale words", sessionID: id)
    #expect(await coordinator.currentSnapshot().provisionalPreview == "Revised recent speech")
    #expect(await coordinator.lastResult() == nil)
}

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["VOXKEY_PREVIEW_TEST_AUDIO"] != nil))
func installedModelShowsUnfinishedSpeechInTheNativeOverlay() async throws {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: try #require(
        ProcessInfo.processInfo.environment["VOXKEY_PREVIEW_TEST_AUDIO"])))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
        frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let samples = Array(UnsafeBufferPointer(start: try #require(buffer.floatChannelData?[0]), count: Int(buffer.frameLength)))
    let transcriber = WhisperTranscriber()
    try await transcriber.prepare(model: ProcessInfo.processInfo.environment["VOXKEY_PREVIEW_TEST_MODEL"] ?? WhisperTranscriber.defaultModel, download: false)
    let input = SyntheticAudioInput(sampleRate: file.processingFormat.sampleRate)
    let capture = AudioCaptureService(makeInput: { _ in input })
    let id = DictationSessionID()
    let coordinator = SessionCoordinator(audioCapture: capture, transcriber: transcriber,
        accessibility: DesktopFixture().service, initialState: .init(phase: .arming(id)))
    let overlay = StatusOverlayController(animationsEnabled: false)
    defer { overlay.window?.orderOut(nil) }
    let consumer = Task {
        for await snapshot in await coordinator.updates { overlay.update(snapshot) }
    }
    await coordinator.startCapture(sessionID: id)
    let started = ContinuousClock.now
    let end = min(samples.count, Int(file.processingFormat.sampleRate * 1.6))
    let chunk = Int(file.processingFormat.sampleRate / 10)
    for offset in stride(from: 0, to: end, by: chunk) {
        input.emit(Array(samples[offset..<min(offset + chunk, end)]))
        try await Task.sleep(for: .milliseconds(100))
    }
    let deadline = started.advanced(by: .seconds(3))
    while await coordinator.currentSnapshot().provisionalPreview == nil, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    let snapshot = await coordinator.currentSnapshot()
    // Complete teardown even when the acceptance assertions fail.
    overlay.update(snapshot)
    let root = try #require(overlay.window?.contentView)
    let visible = descendants(root).compactMap { $0 as? NSTextView }.first?.string ?? ""
    #expect(snapshot.phase == .capturing(id))
    #expect(snapshot.transcriptPreview == nil)
    #expect(snapshot.provisionalPreview?.isEmpty == false)
    #expect(overlay.window?.isVisible == true)
    #expect(!visible.isEmpty)
    #expect(await coordinator.lastResult() == nil)
    if let directory = ProcessInfo.processInfo.environment["VOXKEY_SETTINGS_PREVIEW_DIR"] {
        root.layoutSubtreeIfNeeded()
        if let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(
                to: URL(fileURLWithPath: directory).appendingPathComponent("unfinished-speech-native.png"))
        }
    }
    await coordinator.cancel()
    consumer.cancel()
    await consumer.value
    #expect(await coordinator.currentSnapshot().provisionalPreview == nil)
    // Cancellation has released the shared model before another caller uses it.
    let result = try await transcriber.transcribe(.init(samples: samples,
        sampleRate: file.processingFormat.sampleRate, overflowed: false))
    if case .final(let text) = result { #expect(!text.isEmpty) }
    else { Issue.record("The model must remain usable after preview cancellation") }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VOXKEY_PREVIEW_TEST_AUDIO"] != nil))
func installedModelReleaseAndCancellationInterruptActiveSpeculation() async throws {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: try #require(
        ProcessInfo.processInfo.environment["VOXKEY_PREVIEW_TEST_AUDIO"])))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
        frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let count = min(Int(buffer.frameLength), Int(file.processingFormat.sampleRate * 1.6))
    let samples = Array(UnsafeBufferPointer(start: try #require(buffer.floatChannelData?[0]), count: count))
    let transcriber = WhisperTranscriber()
    try await transcriber.prepare(model: ProcessInfo.processInfo.environment["VOXKEY_PREVIEW_TEST_MODEL"] ?? WhisperTranscriber.defaultModel, download: false)
    var baseline: TranscriptionOutcome?
    for action in ["baseline", "release", "cancel", "baseline"] {
        let input = SyntheticAudioInput(sampleRate: file.processingFormat.sampleRate)
        let capture = AudioCaptureService(makeInput: { _ in input })
        try await capture.start()
        input.emit(samples)
        if action == "baseline" {
            try await capture.finish()
            let result = try await transcriber.transcribeStream(from: capture)
            if let baseline { #expect(result == baseline) }
            else { baseline = result }
            continue
        }
        let previews = AsyncStream.makeStream(of: DecoderPreview.self, bufferingPolicy: .bufferingNewest(1))
        let worker = Task { try await transcriber.transcribeStream(from: capture, decoderPreview: previews.continuation) }
        // The first raw callback is emitted from inside the speculative token
        // loop. Release/cancel there instead of waiting for a completed preview.
        let decodingStarted = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var iterator = previews.stream.makeAsyncIterator()
                return await iterator.next() != nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(decodingStarted)
        let started = ContinuousClock.now
        if action == "cancel" {
            worker.cancel()
            await capture.cancel()
            await #expect(throws: CancellationError.self) { try await worker.value }
        } else {
            try await capture.finish()
            #expect(try await worker.value == baseline)
        }
        print("Active preview \(action): \(started.duration(to: .now))")
        previews.continuation.finish()
    }
}

/// A minute of continuous speech should remain visible without repeatedly
/// submitting almost the entire same audio window on every update.
@Test
func sustainedPreviewBoundsRepeatedAudioAndKeepsFreshWords() throws {
    var transcript = StreamingTranscript()
    var schedule = ProvisionalDecodeSchedule()
    let started = ContinuousClock.now
    let chunk = Array(repeating: Float(0.1), count: 1_600)
    var decodedSamples = 0
    var starts: [Int] = []
    for tick in 1...600 {
        try transcript.append(chunk)
        if let samples = schedule.nextSamples(in: transcript, now: started.advanced(by: .milliseconds(tick * 100))) {
            decodedSamples += samples.count
            starts.append(tick)
            #expect(samples == Array(transcript.samples.suffix(samples.count)))
            #expect(samples.count <= 8 * 16_000)
        }
    }
    #expect(starts.first == 10, "The first words still start decoding after one second")
    #expect(decodedSamples <= transcript.samples.count * 4, "Bound speculative audio work to four times captured audio")
    #expect(starts.count < 40, "Long phrases must not launch a nearly continuous stream of full-window decodes")
    #expect(zip(starts, starts.dropFirst()).allSatisfy { $1 - $0 <= 21 }, "Keep fresh speech visible at least every 2.1 seconds")
    #expect(transcript.consumedSamples == 0 && transcript.confirmedText.isEmpty)
    #expect(transcript.nextWindow(isFinal: true)?.samples == Array(repeating: Float(0.1), count: 60 * 16_000))
    print("Sustained preview schedule: \(starts.count) decodes, \(Double(decodedSamples) / 16_000) audio seconds for 60 seconds captured")
}

@Test
func previewOfNewPhraseDoesNotWaitForThePreviousLongWindow() throws {
    var transcript = StreamingTranscript()
    var schedule = ProvisionalDecodeSchedule()
    let now = ContinuousClock.now
    try transcript.append(Array(repeating: 0.1, count: 8 * 16_000))
    #expect(schedule.nextSamples(in: transcript, now: now) != nil)
    let pendingPhrase = transcript.nextWindow(isFinal: true)
    let phrase = try #require(pendingPhrase)
    transcript.accept("Completed phrase.", window: phrase)
    let fresh = Array(repeating: Float(0.2), count: 16_000)
    try transcript.append(fresh)
    #expect(schedule.nextSamples(in: transcript, now: now.advanced(by: .seconds(1))) == fresh)
    #expect(transcript.confirmedText == "Completed phrase.")
    #expect(transcript.decodeCount == 1)
    #expect(transcript.nextWindow(isFinal: true)?.samples == fresh)
}

@Test
func aPauseRefreshesPreviewBeforeTheRegularBudgetAndOnlyOnce() throws {
    var transcript = StreamingTranscript()
    var schedule = ProvisionalDecodeSchedule()
    let now = ContinuousClock.now
    try transcript.append(Array(repeating: 0.1, count: 8 * 16_000))
    #expect(schedule.nextSamples(in: transcript, now: now) != nil)
    try transcript.append(Array(repeating: 0.1, count: 6_400))
    // Quiet enough for preview speech detection, but not an authoritative cut.
    try transcript.append(Array(repeating: 0.005, count: 4_800))
    #expect(transcript.nextWindow(isFinal: false) == nil)
    let paused = schedule.nextSamples(in: transcript, now: now.advanced(by: .milliseconds(700)))
    let containsLatestWords = paused == Array(transcript.samples.suffix(8 * 16_000))
    #expect(containsLatestWords)
    for second in 1...4 {
        try transcript.append(Array(repeating: 0.005, count: 16_000))
        #expect(schedule.nextSamples(in: transcript, now: now.advanced(by: .seconds(second + 1))) == nil)
    }
    try transcript.append(Array(repeating: 0.1, count: 6_400))
    try transcript.append(Array(repeating: 0.005, count: 4_800))
    #expect(schedule.nextSamples(in: transcript, now: now.advanced(by: .seconds(6))) != nil)
    #expect(transcript.consumedSamples == 0 && transcript.confirmedText.isEmpty)
    #expect(transcript.nextWindow(isFinal: true)?.samples.count == transcript.samples.count)
}

@Test
func shortSpeechPauseDoesNotWaitForOneSecondOrDecodeTrailingSilence() throws {
    var transcript = StreamingTranscript()
    var schedule = ProvisionalDecodeSchedule()
    let speech = Array(repeating: Float(0.1), count: 6_400)
    try transcript.append(speech)
    #expect(schedule.nextSamples(in: transcript) == nil)
    // Also covers a pause noticed after an earlier model call has finished.
    try transcript.append(Array(repeating: 0.005, count: 2 * 16_000))
    #expect(transcript.nextWindow(isFinal: false) == nil)
    let paused = schedule.nextSamples(in: transcript)
    let includesSpeechAndBriefQuiet = paused == speech + Array(repeating: 0.005, count: 4_800)
    #expect(includesSpeechAndBriefQuiet)
    #expect(schedule.nextSamples(in: transcript) == nil)
    #expect(transcript.consumedSamples == 0)
}

@Test
func completedPhraseAndSilenceDoNotRequestCatchUpPreviews() throws {
    var transcript = StreamingTranscript()
    var schedule = ProvisionalDecodeSchedule()
    try transcript.append(Array(repeating: 0.005, count: 3 * 16_000))
    #expect(schedule.nextSamples(in: transcript) == nil)
    try transcript.append(Array(repeating: 0.1, count: 16_000))
    _ = schedule.nextSamples(in: transcript, now: .now.advanced(by: .seconds(1)))
    let pending = transcript.nextWindow(isFinal: true)
    transcript.accept("Already visible.", window: try #require(pending))
    try transcript.append(Array(repeating: 0.005, count: 16_000))
    #expect(schedule.nextSamples(in: transcript, now: .now.advanced(by: .seconds(3))) == nil)
    #expect(transcript.confirmedText == "Already visible.")
}

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["VOXKEY_PREVIEW_TEST_AUDIO"] != nil))
func installedModelPauseShowsCompleteWordsInOverlayBeforeRelease() async throws {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: #require(
        ProcessInfo.processInfo.environment["VOXKEY_PREVIEW_TEST_AUDIO"])))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
        frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let raw = Array(UnsafeBufferPointer(start: try #require(buffer.floatChannelData?[0]), count: Int(buffer.frameLength)))
    // A quiet background above the authoritative pause threshold reproduces
    // a stalled phrase without changing the final decoder's boundaries.
    let speech = raw.map { $0 + 0.005 }
    let engine = WhisperTranscriber()
    try await engine.prepare(model: ProcessInfo.processInfo.environment["VOXKEY_PREVIEW_TEST_MODEL"] ?? WhisperTranscriber.defaultModel, download: false)
    var baseline: TranscriptionOutcome?
    func words(_ text: String) -> [String] { text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init) }
    for observing in [false, true] {
        let input = SyntheticAudioInput(sampleRate: file.processingFormat.sampleRate)
        let capture = AudioCaptureService(makeInput: { _ in input })
        let id = DictationSessionID()
        let coordinator = SessionCoordinator(accessibility: DesktopFixture().service,
            initialState: .init(phase: .capturing(id)))
        let overlay = StatusOverlayController(animationsEnabled: false)
        defer { overlay.window?.orderOut(nil) }
        let previews = AsyncStream.makeStream(of: DecoderPreview.self, bufferingPolicy: .bufferingNewest(1))
        let consumer = Task {
            for await update in previews.stream {
                let text = await engine.textForPreview(update)
                await coordinator.receiveDecoderPreview(update, text: text, sessionID: id)
                overlay.update(await coordinator.currentSnapshot())
            }
        }
        try await capture.start()
        let worker = Task { try await engine.transcribeStream(from: capture,
            decoderPreview: observing ? previews.continuation : nil) { progress in
            await coordinator.receiveTranscriptionProgress(progress, sessionID: id)
        } }
        let chunk = Int(file.processingFormat.sampleRate / 10)
        for offset in stride(from: 0, to: speech.count, by: chunk) {
            input.emit(Array(speech[offset..<min(offset + chunk, speech.count)]))
            try await Task.sleep(for: .milliseconds(100))
        }
        // Keep recording through the pause; never release to obtain these words.
        for _ in 0..<20 {
            input.emit(Array(repeating: 0.005, count: chunk))
            try await Task.sleep(for: .milliseconds(100))
        }
        let pausedSnapshot = await coordinator.currentSnapshot()
        let visible = overlay.window?.contentView.flatMap { root in
            descendants(root).compactMap { $0 as? NSTextView }.first?.string
        } ?? ""
        try await capture.finish()
        let result = try await worker.value
        previews.continuation.finish()
        await consumer.value
        if observing {
            #expect(result == baseline, "Pause previews must preserve final recognition")
            #expect(pausedSnapshot.phase == .capturing(id))
            #expect(pausedSnapshot.transcriptPreview == nil, "The noise floor should prevent an authoritative phrase cut")
            guard case let .final(expected) = try #require(baseline) else { Issue.record("Expected final speech"); return }
            #expect(!expected.isEmpty)
            #expect(words(visible) == words(expected), "All spoken words must be visible during the pause, before release")
            #expect(overlay.window?.isVisible == true)
        } else { baseline = result }
    }
}

/// Microphone notifications can coalesce while inference is busy. A completed
/// pause must survive later voiced frames in the same batch, without replaying
/// an obsolete window that excludes the resumed speech.
@Test
func previewCatchesPauseFollowedByFastSpeechInOneBatch() throws {
    var transcript = StreamingTranscript()
    var schedule = ProvisionalDecodeSchedule()
    let now = ContinuousClock.now
    try transcript.append(Array(repeating: 0.1, count: 8 * 16_000))
    _ = schedule.nextSamples(in: transcript, now: now)
    try transcript.append(Array(repeating: 0.005, count: 4_800))
    try transcript.append(Array(repeating: 0.2, count: 6_400))
    let result = schedule.nextSamples(in: transcript, now: now.advanced(by: .milliseconds(700)))
    let includesResumedSpeech = result == Array(transcript.samples.suffix(8 * 16_000))
    #expect(includesResumedSpeech)
    #expect(schedule.nextSamples(in: transcript, now: now.advanced(by: .seconds(2))) == nil)
    #expect(transcript.consumedSamples == 0)
}

@Test
func repeatedBriefPausesCannotCreateADecodeStorm() throws {
    var transcript = StreamingTranscript()
    var schedule = ProvisionalDecodeSchedule()
    let now = ContinuousClock.now
    var starts: [Int] = []
    for tick in 1...100 {
        // Two voiced frames, three quiet frames, repeated twenty times.
        try transcript.append(Array(repeating: tick % 5 == 1 || tick % 5 == 2 ? 0.1 : 0.005, count: 1_600))
        if let samples = schedule.nextSamples(in: transcript, now: now.advanced(by: .milliseconds(tick * 100))) {
            starts.append(tick)
            #expect(samples.count <= 8 * 16_000)
        }
    }
    #expect(starts.first == 5, "A short first utterance appears at its pause")
    #expect(zip(starts, starts.dropFirst()).allSatisfy { $1 - $0 >= 7 }, "Pause/resume cannot defeat the decode rate limit")
    #expect(zip(starts, starts.dropFirst()).allSatisfy { $1 - $0 <= 10 }, "Repeated pauses still refresh promptly")
}

@Test(arguments: [317, 1_600, 11_200])
func busyPreviewCoalescesPausesAndKeepsNewestAudio(_ chunkSize: Int) throws {
    var transcript = StreamingTranscript()
    var schedule = ProvisionalDecodeSchedule()
    let now = ContinuousClock.now
    let audio = Array(repeating: Float(0.1), count: 6_400)
        + Array(repeating: Float(0.005), count: 4_800)
        + Array(repeating: Float(0.2), count: 6_400)
        + Array(repeating: Float(0.005), count: 4_800)
        + Array(repeating: Float(0.3), count: 3_200)
    for offset in stride(from: 0, to: audio.count, by: chunkSize) {
        try transcript.append(Array(audio[offset..<min(offset + chunkSize, audio.count)]))
        #expect(schedule.nextSamples(in: transcript, now: now, decoderAvailable: false) == nil)
    }
    let next = schedule.nextSamples(in: transcript, now: now)
    let includesAllSpeech = next == audio
    #expect(includesAllSpeech, "Busy decodes defer one request without clipping resumed speech or queuing old windows")
    #expect(schedule.nextSamples(in: transcript, now: now.advanced(by: .seconds(1))) == nil)
    #expect(transcript.consumedSamples == 0 && transcript.confirmedText.isEmpty)
}

@Test
func authoritativeCommitDiscardsDeferredPauseAndNewSpeechRearmsIt() throws {
    var transcript = StreamingTranscript()
    var schedule = ProvisionalDecodeSchedule()
    let now = ContinuousClock.now
    try transcript.append(Array(repeating: 0.1, count: 6_400))
    try transcript.append(Array(repeating: 0.005, count: 4_800))
    #expect(schedule.nextSamples(in: transcript, now: now, decoderAvailable: false) == nil)
    let pending = transcript.nextWindow(isFinal: true)
    let window = try #require(pending)
    transcript.accept("Already committed.", window: window)
    try transcript.append(Array(repeating: 0.005, count: 320)) // different frame alignment
    #expect(schedule.nextSamples(in: transcript, now: now) == nil)
    try transcript.append(Array(repeating: 0.2, count: 6_400))
    try transcript.append(Array(repeating: 0.005, count: 6_400))
    let next = schedule.nextSamples(in: transcript, now: now.advanced(by: .seconds(1)))
    #expect(next != nil)
    #expect(next?.contains(0.1) == false, "Previously committed speech cannot reappear")
    #expect(transcript.confirmedText == "Already committed.")
}

@Test
func breathPausesAndIsolatedNoiseDoNotForceCatchUpDecodes() throws {
    let now = ContinuousClock.now
    for quietFrames in [1, 2] {
        var transcript = StreamingTranscript()
        var schedule = ProvisionalDecodeSchedule()
        try transcript.append(Array(repeating: 0.1, count: 8 * 16_000))
        _ = schedule.nextSamples(in: transcript, now: now)
        try transcript.append(Array(repeating: 0.005, count: quietFrames * 1_600))
        try transcript.append(Array(repeating: 0.1, count: 3_200))
        #expect(schedule.nextSamples(in: transcript, now: now.advanced(by: .seconds(1))) == nil)
    }
    var transcript = StreamingTranscript()
    var schedule = ProvisionalDecodeSchedule()
    try transcript.append(Array(repeating: 0.1, count: 1_600)) // one-frame transient
    try transcript.append(Array(repeating: 0.005, count: 16_000))
    #expect(schedule.nextSamples(in: transcript, now: now) == nil)
}

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["VOXKEY_PREVIEW_RESUME_TEST_AUDIO"] != nil),
      arguments: [200, 400, 1_200])
func installedModelPauseThenFastSpeechCatchesUpBeforeRelease(_ pauseMS: Int) async throws {
    func load(_ key: String) throws -> (samples: [Float], rate: Double) {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: #require(ProcessInfo.processInfo.environment[key])))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let raw = Array(UnsafeBufferPointer(start: try #require(buffer.floatChannelData?[0]), count: Int(buffer.frameLength)))
        return (raw.map { $0 + 0.005 }, file.processingFormat.sampleRate)
    }
    func words(_ text: String) -> [String] { text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init) }
    let normal = try load("VOXKEY_PREVIEW_TEST_AUDIO")
    let fast = try load("VOXKEY_PREVIEW_RESUME_TEST_AUDIO")
    try #require(normal.rate == fast.rate)
    let audio = normal.samples + Array(repeating: Float(0.005), count: Int(normal.rate) * pauseMS / 1_000) + fast.samples
    try #require(audio.count < Int(normal.rate * 7), "Use short synthetic fixtures within the eight-second preview window")
    let engine = WhisperTranscriber()
    try await engine.prepare(model: ProcessInfo.processInfo.environment["VOXKEY_PREVIEW_TEST_MODEL"] ?? WhisperTranscriber.defaultModel, download: false)
    var baseline: TranscriptionOutcome?
    for observing in [false, true] {
        let input = SyntheticAudioInput(sampleRate: normal.rate)
        let capture = AudioCaptureService(makeInput: { _ in input })
        let updates = AsyncStream.makeStream(of: DecoderPreview.self, bufferingPolicy: .bufferingNewest(1))
        let id = DictationSessionID()
        let coordinator = SessionCoordinator(accessibility: DesktopFixture().service, initialState: .init(phase: .capturing(id)))
        let consumer = Task {
            for await update in updates.stream {
                await coordinator.receiveDecoderPreview(update, text: await engine.textForPreview(update), sessionID: id)
            }
        }
        try await capture.start()
        let worker = Task { try await engine.transcribeStream(from: capture,
            decoderPreview: observing ? updates.continuation : nil) { progress in
                await coordinator.receiveTranscriptionProgress(progress, sessionID: id)
            }
        }
        let chunk = Int(normal.rate / 10)
        if observing {
            for offset in stride(from: 0, to: audio.count, by: chunk) {
                input.emit(Array(audio[offset..<min(offset + chunk, audio.count)]))
                try await Task.sleep(for: .milliseconds(100))
            }
        } else { input.emit(audio) }
        if observing {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            let expected: String
            if case .final(let text) = baseline { expected = text } else { expected = "" }
            while ContinuousClock.now < deadline {
                input.emit(Array(repeating: 0.005, count: chunk))
                try await Task.sleep(for: .milliseconds(100))
                if words(await coordinator.currentSnapshot().provisionalPreview ?? "") == words(expected) { break }
            }
            let snapshot = await coordinator.currentSnapshot()
            #expect(!expected.isEmpty)
            #expect(snapshot.phase == .capturing(id))
            #expect(snapshot.transcriptPreview == nil)
            #expect(words(snapshot.provisionalPreview ?? "") == words(expected), "Catch up to the fast resumed speech before release")
        }
        try await capture.finish()
        let result = try await worker.value
        updates.continuation.finish()
        await consumer.value
        if observing { #expect(result == baseline, "Pause and speech speed must not change final recognition") }
        else { baseline = result }
    }
}
