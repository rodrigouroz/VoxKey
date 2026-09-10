@preconcurrency import AVFoundation
import CoreML
import Foundation
import Synchronization
import Testing
@preconcurrency import WhisperKit
@testable import VoxKeyApp

/// Explicit research run only: synthetic audio and installed models, no microphone or downloads.
@Test(.enabled(if: ProcessInfo.processInfo.environment["VOXKEY_PERFORMANCE_ROOT"] != nil))
func benchmarkCombinedInference() async throws {
    let environment = ProcessInfo.processInfo.environment
    let root = URL(fileURLWithPath: try #require(environment["VOXKEY_PERFORMANCE_ROOT"]))
    let assets = URL(fileURLWithPath: try #require(environment["VOXKEY_GRAMMAR_TEST_ASSETS"]))
    let asrMode = environment["VOXKEY_ASR_COMPUTE"] ?? "neural"
    let grammarMode = environment["VOXKEY_GEC_COMPUTE"] ?? "gpu"
    let run = environment["VOXKEY_PERFORMANCE_RUN"] ?? "0"
    let file = root.appendingPathComponent("combined-\(asrMode)-\(grammarMode)-\(run).jsonl")
    FileManager.default.createFile(atPath: file.path, contents: nil)
    let log = try FileHandle(forWritingTo: file)
    defer { try? log.close() }
    func emit(_ row: [String: Any]) throws {
        try log.write(contentsOf: JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data([10]))
    }
    let started = ContinuousClock.now
    let engine = try await PerformanceWhisper(mode: asrMode)
    try emit(["type": "loadASR", "milliseconds": performanceMilliseconds(since: started)])
    let grammar = GrammarCorrector(assets: assets, computeUnits: performanceUnits(grammarMode))
    await grammar.setEnabled(true)
    let grammarStarted = ContinuousClock.now
    #expect(await grammar.correct("Okay, make sense, thanks.", enabledForSession: true) == "Okay, makes sense, thanks.")
    try emit(["type": "loadGrammarAndFirstCorrection", "milliseconds": performanceMilliseconds(since: grammarStarted)])
    struct Audio: Decodable { let id: String; let path: String; let reference: String }
    let audio = try JSONDecoder().decode([Audio].self, from: Data(contentsOf: root.appendingPathComponent("audio.json")))
    var samples: [[Float]] = []
    for fixture in audio {
        samples.append(try AudioProcessor.loadAudioAsFloatArray(fromPath: fixture.path))
    }
    let stressCount = environment["VOXKEY_PERFORMANCE_PHASE"] == "asr" ? 0 : 90
    let stressText = Array(repeating: "Okay, make sense, thanks.", count: stressCount).joined(separator: " ")
    let stressExpected = Array(repeating: "Okay, makes sense, thanks.", count: stressCount).joined(separator: " ")
    // Counterbalance serial/concurrent ordering, discard round zero in analysis.
    for round in 0..<4 {
        for index in audio.indices {
            for overlap in (round + index).isMultiple(of: 2) ? [false, true] : [true, false] {
                let start = ContinuousClock.now
                let text: String
                let corrected: String
                let decodeMS: Double
                let correctionMS: Double
                if overlap {
                    let work = Task {
                        let correctionStart = ContinuousClock.now
                        let result = await grammar.correct(stressText, enabledForSession: true)
                        return (result, performanceMilliseconds(since: correctionStart))
                    }
                    text = try await engine.decode(samples[index])
                    decodeMS = performanceMilliseconds(since: start)
                    (corrected, correctionMS) = await work.value
                } else {
                    text = try await engine.decode(samples[index])
                    decodeMS = performanceMilliseconds(since: start)
                    let correctionStart = ContinuousClock.now
                    corrected = await grammar.correct(stressText, enabledForSession: true)
                    correctionMS = performanceMilliseconds(since: correctionStart)
                }
                #expect(corrected == stressExpected)
                try emit(["type": "combined", "round": round, "fixture": audio[index].id,
                          "overlap": overlap, "audioSeconds": Double(samples[index].count) / 16000,
                          "asrMilliseconds": decodeMS, "grammarMilliseconds": correctionMS,
                          "totalMilliseconds": performanceMilliseconds(since: start),
                          "reference": audio[index].reference, "transcription": text,
                          "thermalState": ProcessInfo.processInfo.thermalState.rawValue])
            }
        }
    }
    // Packing fewer calls trades sentence context for speed. Record outputs, not just timing.
    struct GrammarFixture: Decodable { let input: String; let output: String }
    let fixturesURL = try #require(Bundle.module.url(forResource: "coreml-fp16", withExtension: "json", subdirectory: "Grammar"))
    let fixtures = try JSONDecoder().decode([GrammarFixture].self, from: Data(contentsOf: fixturesURL))
    for round in 0..<4 {
        for groupSize in [1, 2, 4, 8] {
            for index in stride(from: 0, to: fixtures.count, by: groupSize) {
                let group = fixtures[index..<min(index + groupSize, fixtures.count)]
                let input = group.map(\.input).joined(separator: " ")
                let start = ContinuousClock.now
                let output = await grammar.correct(input, enabledForSession: true)
                try emit(["type": "grammarPacking", "round": round, "groupSize": groupSize,
                          "index": index, "milliseconds": performanceMilliseconds(since: start),
                          "input": input, "output": output, "expected": group.map(\.output).joined(separator: " ")])
            }
        }
    }
    await grammar.setEnabled(false)
    print("Performance evidence: \(file.path)")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VOXKEY_STREAMING_PERFORMANCE"] != nil))
func benchmarkCorrectionDuringRealTimeCapture() async throws {
    let environment = ProcessInfo.processInfo.environment
    let root = URL(fileURLWithPath: try #require(environment["VOXKEY_STREAMING_PERFORMANCE"]))
    let assets = URL(fileURLWithPath: try #require(environment["VOXKEY_GRAMMAR_TEST_ASSETS"]))
    let cold = environment["VOXKEY_STREAMING_COLD"] == "1"
    let inputName = environment["VOXKEY_STREAMING_INPUT"] ?? "stream"
    let referenceText = try String(contentsOf: root.appendingPathComponent("\(inputName).txt"), encoding: .utf8)
    let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: root.appendingPathComponent("\(inputName).aiff").path)
    let mode = environment["VOXKEY_ASR_COMPUTE"] ?? "gpu"
    let devices = mode.split(separator: "-").map(String.init)
    let transcriber = WhisperTranscriber(computeOptions: ModelComputeOptions(
        audioEncoderCompute: performanceUnits(devices[0]), textDecoderCompute: performanceUnits(devices.last!)))
    try await transcriber.prepare(download: false)
    let grammar = GrammarCorrector(assets: assets, computeUnits: .cpuAndGPU)
    await grammar.setEnabled(true)
    if !cold { _ = await grammar.correct("Okay, make sense, thanks.", enabledForSession: true) }
    let file = root.appendingPathComponent("streaming-\(mode)-\(inputName)-\(cold ? "cold" : "warm").jsonl")
    FileManager.default.createFile(atPath: file.path, contents: nil)
    let log = try FileHandle(forWritingTo: file)
    defer { try? log.close() }
    for round in 0..<3 {
        for overlap in round.isMultiple(of: 2) ? [false, true] : [true, false] {
            if cold {
                await grammar.setEnabled(false)
                await grammar.setEnabled(true)
            }
            let pipeline = overlap ? GrammarCorrectionSession(corrector: grammar, enabled: true) : nil
            let input = SyntheticAudioInput(sampleRate: 16000)
            let capture = AudioCaptureService(makeInput: { _ in input })
            let passes = Mutex(0)
            try await capture.start()
            let worker = Task {
                try await transcriber.transcribeStream(from: capture) { update in
                    passes.withLock { $0 = update.decodeCount }
                    pipeline?.observe(update.confirmedText)
                }
            }
            let start = ContinuousClock.now
            for offset in stride(from: 0, to: samples.count, by: 1600) {
                let end = min(offset + 1600, samples.count)
                input.emit(Array(samples[offset..<end]))
                try await Task.sleep(until: start.advanced(by: .seconds(Double(end) / 16000)), clock: .continuous)
            }
            let passesBeforeRelease = passes.withLock { $0 }
            let release = ContinuousClock.now
            try await capture.finish()
            let outcome = try await worker.value
            let transcriptionMS = performanceMilliseconds(since: release)
            guard case let .final(text) = outcome else { throw TranscriptionError.emptyResult }
            let output: String
            if let pipeline { output = await pipeline.finish(text) }
            else { output = await grammar.correct(text, enabledForSession: true) }
            let totalMS = performanceMilliseconds(since: release)
            let reference = await grammar.correct(text, enabledForSession: true)
            #expect(output == reference, "Incremental scheduling must match final-context correction")
            if samples.count > 160_000 { #expect(passesBeforeRelease > 0) }
            #expect(performanceWords(text) == performanceWords(referenceText))
            let row: [String: Any] = ["round": round, "overlap": overlap,
                "audioSeconds": Double(samples.count) / 16000, "releaseASRMilliseconds": transcriptionMS,
                "releaseTotalMilliseconds": totalMS, "decodesBeforeRelease": passesBeforeRelease,
                "transcription": text, "reference": referenceText, "correction": output, "parity": output == reference, "coldGrammar": cold,
                "thermalState": ProcessInfo.processInfo.thermalState.rawValue]
            try log.write(contentsOf: JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data([10]))
        }
    }
    await grammar.setEnabled(false)
    print("Streaming performance evidence: \(file.path)")
}

private func performanceUnits(_ mode: String) -> MLComputeUnits {
    switch mode { case "gpu": .cpuAndGPU; case "neural": .cpuAndNeuralEngine; case "cpu": .cpuOnly; default: .all }
}

private func performanceMilliseconds(since start: ContinuousClock.Instant) -> Double {
    let elapsed = start.duration(to: .now).components
    return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
}

private actor PerformanceWhisper {
    private let engine: WhisperKit
    init(mode: String) async throws {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("huggingface")
        let folder = base.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(WhisperTranscriber.defaultModel)")
        let devices = mode.split(separator: "-").map(String.init)
        engine = try await WhisperKit(WhisperKitConfig(
            model: WhisperTranscriber.defaultModel, downloadBase: base, modelFolder: folder.path,
            computeOptions: ModelComputeOptions(audioEncoderCompute: performanceUnits(devices[0]), textDecoderCompute: performanceUnits(devices.last!)),
            verbose: false, logLevel: .none, prewarm: true, load: true, download: false))
    }
    func decode(_ samples: [Float]) async throws -> String {
        // Match production's streaming decode configuration, with no vocabulary or prior phrase.
        let results = try await engine.transcribe(audioArray: samples, decodeOptions: DecodingOptions(
            verbose: false, task: .transcribe, language: "en", temperature: 0,
            temperatureFallbackCount: 3, usePrefillPrompt: true,
            skipSpecialTokens: true, withoutTimestamps: true, windowClipTime: 0,
            suppressBlank: true, compressionRatioThreshold: 2.4, logProbThreshold: -1,
            noSpeechThreshold: 0.6, concurrentWorkerCount: 1, chunkingStrategy: ChunkingStrategy.none))
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private func performanceWords(_ text: String) -> [String] {
    text.lowercased().replacingOccurrences(of: "forty two", with: "42")
        .split { !$0.isLetter && !$0.isNumber }.map(String.init)
}
