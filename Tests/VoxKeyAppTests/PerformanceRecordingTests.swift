#if VOXKEY_PERFORMANCE && !VOXKEY_RELEASE
import Foundation
@preconcurrency import AVFoundation
import Testing
import VoxKeyCore
@testable import VoxKeyApp

@Test(.enabled(if: ProcessInfo.processInfo.environment["VOXKEY_PREVIEW_TEST_AUDIO"] != nil))
func performanceRecordingPreservesRealRecognitionAndCapturesPipeline() async throws {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: #require(ProcessInfo.processInfo.environment["VOXKEY_PREVIEW_TEST_AUDIO"])))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let samples = Array(UnsafeBufferPointer(start: try #require(buffer.floatChannelData?[0]), count: Int(buffer.frameLength)))
    let engine = WhisperTranscriber()
    try await engine.prepare(download: false)
    let input = SyntheticAudioInput(sampleRate: file.processingFormat.sampleRate)
    let capture = AudioCaptureService(makeInput: { _ in input })
    var baseline: TranscriptionOutcome?
    for measured in [false, true] {
        let session = PerformanceSession(model: .distilCompressed, language: "en", improvementEnabled: false)
        PerformanceRecording.shared.useForTesting(measured ? session : nil)
        defer { PerformanceRecording.shared.useForTesting(nil) }
        try await capture.start()
        session.mark(.captureStarted)
        input.emit(samples)
        session.mark(.releaseRequested)
        try await capture.finish()
        let result = try await engine.transcribeStream(from: capture)
        guard case let .final(text) = result else { Issue.record("Expected real recognition"); return }
        #expect(!text.isEmpty)
        if measured {
            #expect(result == baseline)
            let record = try #require(session.finish(.noDestination))
            #expect(try #require(record.totals["captureAudioSeconds"]) > 0)
            #expect(try #require(record.totals["resampleMS"]) > 0)
            #expect(try #require(record.totals["authoritativeDecodeMS"]) > 0)
            #expect(try #require(record.totals["finalTailAudioSeconds"]) > 0)
            #expect(record.milestonesMS["recognitionReady"] != nil)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            try PerformanceRecording.save(record, to: directory)
            let data = try Data(contentsOf: directory.appendingPathComponent("\(record.id.uuidString).json"))
            #expect(!String(decoding: data, as: UTF8.self).contains(text))
        } else { baseline = result }
    }
}

@Test func performanceRecordsAreContentFreeAndFinalizeOnce() throws {
    let session = PerformanceSession(model: .distilCompressed, language: "en", improvementEnabled: true)
    session.mark(.captureStarted)
    session.add(.previewDecodes, 2)
    session.add(.previewAudioSeconds, 8)
    session.maximum(.maximumUncommittedAudioSeconds, 5)
    session.maximum(.maximumUncommittedAudioSeconds, 2)
    session.mark(.releaseRequested)
    #expect(session.released)
    session.mark(.recognitionReady)
    session.firstPreview()
    let record = try #require(session.finish(.delivered))
    session.add(.previewDecodes, 100)
    #expect(session.finish(.failed) == nil)
    #expect(record.totals["previewDecodes"] == 2)
    #expect(record.totals["maximumUncommittedAudioSeconds"] == 5)
    #expect(try #require(record.milestonesMS["finished"]) >= #require(record.milestonesMS["releaseRequested"]))
    let data = try JSONEncoder().encode(record)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(json.keys) == Set(["schemaVersion", "id", "date", "build", "model", "language", "improvementEnabled", "outcome",
        "milestonesMS", "totals", "processCPUTimeMS", "captureProcessCPUTimeMS", "sampledPeakResidentBytes", "thermalStateAtStart", "thermalStateAtEnd"]))
}

@Test func performanceRecordsPersistPrivatelyWithBoundedRetention() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    for _ in 0..<3 {
        let session = PerformanceSession(model: .distilCompressed, language: "en", improvementEnabled: false)
        session.add(.captureAudioSeconds, 12)
        session.mark(.releaseRequested)
        let record = try #require(session.finish(.cancelled))
        try PerformanceRecording.save(record, to: directory, maximumRecords: 2)
    }
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    #expect(files.count == 2)
    #expect((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    for file in files {
        let record = try decoder.decode(PerformanceRecord.self, from: Data(contentsOf: file))
        #expect(record.outcome == "cancelled")
        #expect(record.totals["captureAudioSeconds"] == 12)
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 86_400)], ofItemAtPath: file.path)
    }
    let fresh = PerformanceSession(model: .distilCompressed, language: nil, improvementEnabled: false)
    try PerformanceRecording.save(#require(fresh.finish(.failed)), to: directory)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
}

@MainActor
@Test(arguments: [false, true])
func performanceDiagnosticsPreserveDeliveryAndExistingMeasurements(web: Bool) async throws {
    let fixture = DesktopFixture(web: web)
    let session = PerformanceSession(model: .distilCompressed, language: "en", improvementEnabled: true)
    PerformanceRecording.shared.useForTesting(session)
    defer { PerformanceRecording.shared.useForTesting(nil) }
    session.mark(.captureStarted)
    session.add(.captureAudioSeconds, 8)
    session.add(.previewDecodes, 3)
    let token = try #require(await fixture.service.captureCurrentDestination().token)
    #expect(await fixture.service.deliver("Diagnostic privacy sample", to: token) == .delivered)
    await fixture.service.waitForPendingPaste()
    #expect(fixture.editor.string == "Diagnostic privacy sample")
    #expect(fixture.pasteCount == (web ? 1 : 0))
    #expect(fixture.directWriteCount == (web ? 0 : 1))
    let record = try #require(session.finish(.delivered))
    #expect(record.destination?.status == "captured")
    #expect(record.destination?.applicationCategory == "other")
    #expect(record.delivery?.status == "delivered")
    #expect(record.delivery?.deliveryRoute == (web ? "paste" : "accessibilitySelection"))
    #expect(record.delivery?.confirmation == "verified")
    #expect(record.totals["previewDecodes"] == 3)
    #expect(record.totals["captureAudioSeconds"] == 8)
    #expect(record.milestonesMS["captureStarted"] != nil)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try PerformanceRecording.save(record, to: directory)
    let data = try Data(contentsOf: directory.appendingPathComponent("\(record.id.uuidString).json"))
    let serialized = String(decoding: data, as: UTF8.self)
    #expect(!serialized.contains(fixture.editor.string))
    #expect(!serialized.contains("Fixture"))
    #expect(!serialized.contains("original clipboard"))
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let restored = try decoder.decode(PerformanceRecord.self, from: data)
    #expect(restored.delivery?.confirmation == "verified")
    // Reports from the original performance build have neither optional field.
    var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    legacy.removeValue(forKey: "destination")
    legacy.removeValue(forKey: "delivery")
    let old = try decoder.decode(PerformanceRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(old.destination == nil && old.delivery == nil)
    #expect(old.totals == restored.totals)
}

@MainActor
@Test(arguments: [false, true])
func performanceDiagnosticsExplainRejectedFocusWithoutInserting(secure: Bool) async throws {
    let fixture = DesktopFixture()
    fixture.focusAvailable = false
    fixture.secureInputEnabled = secure
    fixture.timing.focusResolutionTimeout = .milliseconds(10)
    let session = PerformanceSession(model: .distilCompressed, language: "en", improvementEnabled: false)
    PerformanceRecording.shared.useForTesting(session)
    defer { PerformanceRecording.shared.useForTesting(nil) }
    let assessment = await fixture.service.captureCurrentDestination()
    #expect(assessment.token == nil)
    #expect(assessment.failure == (secure ? .secureDestination : .focusUnavailable))
    #expect(fixture.editor.string.isEmpty)
    #expect(fixture.pasteCount == 0 && fixture.directWriteCount == 0)
    let record = try #require(session.finish(.noDestination))
    #expect(record.destination?.status == (secure ? "secureDestination" : "focusUnavailable"))
    #expect(record.delivery == nil)
    if !secure {
        #expect(record.destination?.focusAttempts.last?.searchResult == "no_focused_window")
        #expect(try #require(record.destination?.resolutionAttempts) > 0)
    }
}

/// Opt-in on-device comparison using generated speech fed at microphone speed.
/// The same real pipeline must return the same final text with previews on/off.
@Test(.enabled(if: ProcessInfo.processInfo.environment["VOXKEY_PREVIEW_BENCHMARK_AUDIO"] != nil))
func installedModelMeasuresSustainedPreviewWork() async throws {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: #require(
        ProcessInfo.processInfo.environment["VOXKEY_PREVIEW_BENCHMARK_AUDIO"])))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let samples = Array(UnsafeBufferPointer(start: try #require(buffer.floatChannelData?[0]), count: Int(buffer.frameLength)))
    let model = ProcessInfo.processInfo.environment["VOXKEY_PREVIEW_TEST_MODEL"] ?? WhisperTranscriber.defaultModel
    let engine = WhisperTranscriber()
    try await engine.prepare(model: model, download: false)
    _ = try await engine.transcribe(.init(samples: samples, sampleRate: file.processingFormat.sampleRate, overflowed: false))
    var baseline: TranscriptionOutcome?
    for previewing in [false, true] {
        let input = SyntheticAudioInput(sampleRate: file.processingFormat.sampleRate)
        let capture = AudioCaptureService(makeInput: { _ in input })
        let session = PerformanceSession(model: try #require(TranscriptionModel(rawValue: model)), language: "en", improvementEnabled: false)
        PerformanceRecording.shared.useForTesting(session)
        defer { PerformanceRecording.shared.useForTesting(nil) }
        let previews = AsyncStream.makeStream(of: DecoderPreview.self, bufferingPolicy: .bufferingNewest(1))
        let consumer = Task {
            var first: ContinuousClock.Instant?
            var lastRevision = -1
            var visibleRevisions = 0
            for await update in previews.stream {
                if !(await engine.textForPreview(update)).isEmpty {
                    first = first ?? .now
                    if update.revision != lastRevision { visibleRevisions += 1; lastRevision = update.revision }
                }
            }
            return (first, visibleRevisions)
        }
        try await capture.start()
        session.mark(.captureStarted)
        let started = ContinuousClock.now
        let worker = Task { try await engine.transcribeStream(from: capture,
            decoderPreview: previewing ? previews.continuation : nil) }
        let chunk = Int(file.processingFormat.sampleRate / 10)
        for offset in stride(from: 0, to: samples.count, by: chunk) {
            input.emit(Array(samples[offset..<min(offset + chunk, samples.count)]))
            try await Task.sleep(for: .milliseconds(100))
        }
        session.mark(.releaseRequested)
        try await capture.finish()
        let result = try await worker.value
        previews.continuation.finish()
        let (first, visibleRevisions) = await consumer.value
        guard case let .final(text) = result else { Issue.record("Expected generated speech transcription"); return }
        #expect(!text.isEmpty)
        if previewing {
            #expect(result == baseline, "Speculation must preserve final recognition on sustained speech")
            #expect(first != nil && visibleRevisions > 1, "Keep updating visible speech while recording")
            if let first { #expect(started.duration(to: first) < .seconds(3)) }
        } else { baseline = result }
        let record = try #require(session.finish(.noDestination))
        let firstMS = first.map { Double(started.duration(to: $0).components.attoseconds) / 1e15
            + Double(started.duration(to: $0).components.seconds) * 1_000 } ?? 0
        print("PREVIEW_BENCHMARK observing=\(previewing) model=\(model) firstMS=\(firstMS) visibleRevisions=\(visibleRevisions) totals=\(record.totals) stopMS=\(record.milestonesMS["finished"]! - record.milestonesMS["releaseRequested"]!) cpuMS=\(record.processCPUTimeMS)")
    }
}
#endif
