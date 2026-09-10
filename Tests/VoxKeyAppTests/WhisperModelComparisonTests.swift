import Foundation
import Testing
@preconcurrency import WhisperKit
@testable import VoxKeyApp

/// Opt-in research using synthetic/public fixtures only. Never records microphone audio.
@Test(.enabled(if: ProcessInfo.processInfo.environment["VOXKEY_MODEL_COMPARISON"] != nil))
func compareWhisperCandidate() async throws {
    let environment = ProcessInfo.processInfo.environment
    let root = URL(fileURLWithPath: try #require(environment["VOXKEY_MODEL_COMPARISON"]))
    let id = try #require(environment["VOXKEY_COMPARISON_MODEL"])
    let manifest = try JSONDecoder().decode(ComparisonManifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
    let candidate = try #require(manifest.models.first { $0.id == id })
    let output = root.appendingPathComponent("\(id).jsonl")
    try Data().write(to: output)
    let log = try FileHandle(forWritingTo: output)
    defer { try? log.close() }
    func emit(_ row: [String: Any]) throws {
        try log.write(contentsOf: JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data([10]))
        try log.synchronize()
    }
    let loadStart = ContinuousClock.now
    let engine = try await ComparisonEngine(candidate: candidate)
    try emit(["type": "load", "model": id, "milliseconds": comparisonMilliseconds(loadStart),
              "revision": candidate.revision])
    let fixtures = manifest.fixtures.filter { candidate.languages.contains($0.language) }
    #expect(!fixtures.isEmpty)
    // Round zero includes first inference. Two subsequent rounds measure warm behavior.
    for round in 0..<3 {
        for fixture in fixtures {
            let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: fixture.path)
            #expect(!samples.isEmpty)
            for mode in candidate.languages.count > 1 ? ["explicit", "auto"] : ["explicit"] {
                let start = ContinuousClock.now
                let result = try await engine.decode(samples, language: mode == "auto" ? nil : fixture.language)
                try emit(["type": "decode", "model": id, "round": round, "fixture": fixture.id,
                          "language": fixture.language, "mode": mode, "detectedLanguage": result.language,
                          "audioSeconds": Double(samples.count) / 16000,
                          "milliseconds": comparisonMilliseconds(start), "reference": fixture.reference,
                          "transcription": result.text])
            }
        }
    }
    print("Whisper comparison evidence: \(output.path)")
}

private struct ComparisonManifest: Decodable {
    let models: [ComparisonCandidate]
    let fixtures: [ComparisonFixture]
}

private struct ComparisonCandidate: Decodable {
    let id: String
    let variant: String
    let folder: String
    let languages: [String]
    let revision: String
}

private struct ComparisonFixture: Decodable {
    let id: String
    let path: String
    let reference: String
    let language: String
}

private actor ComparisonEngine {
    private let engine: WhisperKit

    init(candidate: ComparisonCandidate) async throws {
        engine = try await WhisperKit(WhisperKitConfig(
            model: candidate.variant, modelFolder: candidate.folder,
            computeOptions: ModelComputeOptions(audioEncoderCompute: .all, textDecoderCompute: .all),
            verbose: false, logLevel: .none,
            prewarm: true, load: true, download: false))
    }

    func decode(_ samples: [Float], language: String?) async throws -> (text: String, language: String) {
        // Same options as production's phrase decoder, except the explicit fixture language.
        // Grammar correction, vocabulary, and preceding-phrase prompts are intentionally absent.
        let options = DecodingOptions(
            verbose: false, task: .transcribe, language: language, temperature: 0,
            temperatureFallbackCount: 3, usePrefillPrompt: true,
            detectLanguage: language == nil,
            skipSpecialTokens: true, withoutTimestamps: true, windowClipTime: 0,
            suppressBlank: true, compressionRatioThreshold: 2.4, logProbThreshold: -1,
            noSpeechThreshold: 0.6, concurrentWorkerCount: 1, chunkingStrategy: ChunkingStrategy.none)
        let results = try await engine.transcribe(audioArray: samples, decodeOptions: options)
        guard !results.isEmpty else { throw TranscriptionError.emptyResult }
        return (results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines), results[0].language)
    }
}

private func comparisonMilliseconds(_ start: ContinuousClock.Instant) -> Double {
    let duration = start.duration(to: .now).components
    return Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
}
