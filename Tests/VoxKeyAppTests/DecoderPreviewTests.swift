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
