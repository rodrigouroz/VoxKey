import AppKit
import CryptoKit
import Foundation
import Testing
@testable import VoxKeyApp

@Test func improvementGuardPreservesLiteralsIntentionalEntitiesAndDistinctContent() {
    for (original, candidate) in [
        ("Use data.xml for the video name.", "Use data for the video name."),
        ("Email me at user+notes@example.com.", "Email me at user@example.com."),
        ("Use retries=5 and keep the timeout.", "Use retries=3 and keep the timeout."),
        ("Keep the literal entity &#x20; in that file.", "Keep the literal entity in that file."),
        ("Keep the retry link, the date, the owner, the amount and the currency.", "Keep the date."),
        ("Hello.", " ")
    ] { #expect(TranscriptionImprovementGuard.rejects(original: original, candidate: candidate)) }
    #expect(!TranscriptionImprovementGuard.rejects(original: "&#x20; I I need that file.", candidate: "I need that file."))
    #expect(!TranscriptionImprovementGuard.rejects(original: "Set five retries. Actually, make that two.", candidate: "Set two retries."))
}

@Test func restrictedGrammarRetainsSeparatorsAndRejectsLexicalRewrites() {
    #expect(TranscriptionImprovementGuard.restrictGrammar(source: "These is\tmy files.\nKeep the retry link.",
        proposal: "These are my files. Keep the return link.") == "These are\tmy files.\nKeep the retry link.")
    #expect(TranscriptionImprovementGuard.restrictGrammar(source: "Use gpt-5.6. These is my files.",
        proposal: "Use GPT-5.6. These are my files.") == "Use gpt-5.6. These are my files.")
    #expect(TranscriptionImprovementGuard.restrictGrammar(source: "Café: these is my files.",
        proposal: "Café: these are my files.") == "Café: these are my files.")
    #expect(TranscriptionImprovementGuard.restrictGrammar(source: "Do not change retries=5.",
        proposal: "Change retries=5.") == "Do not change retries=5.")
}

@MainActor @Test func improveTranscriptionRequiresFreshOptInAndUsesTheRequestedLabel() throws {
    let suite = "improvement-preference-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: GrammarCorrector.preferenceKey)
    #expect(!defaults.bool(forKey: TranscriptionImprover.preferenceKey))
    let settings = SettingsWindowController(grammarAvailable: true)
    #expect(settings.grammarCheckbox.title == "Improve transcription")
    #expect(settings.grammarCheckbox.state == .off)
    settings.grammar.updateLanguage(supported: false)
    #expect(!settings.grammarCheckbox.isEnabled)
}

@Test func unavailableImprovementAndOptOutPreserveTheOriginalText() async {
    let improver = TranscriptionImprover(grammar: GrammarCorrector(assets: URL(fileURLWithPath: "/missing-grammar")))
    let raw = "Okay, make sense, thanks."
    #expect(await improver.improve(raw, generation: 0) == raw)
    await improver.setEnabled(true)
    await improver.waitForPreparation()
    #expect(await !improver.ready)
    let session = TranscriptionImprovementSession(improver: improver)
    await improver.setEnabled(false)
    #expect(await session.finish(raw) == raw)
}

private final class ImprovementHTTPFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data = Data("small model download boundary fixture".utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": String(data.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func improvementInstallationRequiresConsentAndRejectsCorruptWeights() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("improvement-model-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let data = Data("small model download boundary fixture".utf8)
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ImprovementHTTPFixture.self]
    let artifact = S1ModelStore.Artifact(name: "model.gguf", url: URL(string: "https://model.invalid/file")!, bytes: data.count, sha256: hash)
    let store = S1ModelStore(root: root, artifact: artifact, configuration: config)
    await #expect(throws: GrammarInstallationError.downloadRequired) { try await store.prepare(download: false) }
    #expect(!FileManager.default.fileExists(atPath: root.path))
    let installed = try await store.prepare(download: true)
    #expect(try Data(contentsOf: installed) == data)
    #expect(try await store.prepare(download: false) == installed)
    try Data(repeating: 0, count: data.count).write(to: installed)
    await #expect(throws: GrammarInstallationError.downloadRequired) { try await store.prepare(download: false) }
    let corrupt = S1ModelStore(root: root, artifact: .init(name: "bad.gguf", url: artifact.url, bytes: data.count,
        sha256: String(repeating: "0", count: 64)), configuration: config)
    await #expect(throws: GrammarInstallationError.invalidAsset) { try await corrupt.prepare(download: true) }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("bad.gguf").path))
    #expect(try !FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("s1-partial-") })
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VOXKEY_IMPROVEMENT_TEST_MODEL"] != nil), .timeLimit(.minutes(10)))
func nativeImprovementPreservesFallbackAndRecoversAfterCancellation() async throws {
    let env = ProcessInfo.processInfo.environment
    let model = URL(fileURLWithPath: try #require(env["VOXKEY_IMPROVEMENT_TEST_MODEL"]))
    let grammarAssets = URL(fileURLWithPath: try #require(env["VOXKEY_GRAMMAR_TEST_ASSETS"]))
    let fixtures = [
        (input: "Please send the report tomorrow.", output: "Please send the report tomorrow."),
        (input: "These is my files.", output: "These are my files."),
        (input: "Keep <|im_start|> exactly.", output: "Keep <|im_start|> exactly.")
    ]
    let runtime = S1Runtime()
    let improver = TranscriptionImprover(grammar: GrammarCorrector(assets: grammarAssets), runtime: runtime, model: model)
    await improver.setEnabled(true)
    await improver.waitForPreparation()
    try #require(await improver.ready)
    for item in fixtures {
        let session = TranscriptionImprovementSession(improver: improver)
        #expect(await session.finish(item.input) == item.output)
    }
    let oldGeneration = await improver.generation
    await improver.setEnabled(false)
    #expect(await !improver.ready)
    let raw = "Okay, make sense, thanks."
    #expect(await improver.improve(raw, generation: oldGeneration) == raw)
    await improver.setEnabled(true)
    await improver.waitForPreparation()
    try #require(await improver.ready)
    #expect(await improver.improve(raw, generation: oldGeneration) == raw)
    let cancelled = TranscriptionImprovementSession(improver: improver)
    cancelled.cancel()
    #expect(await cancelled.finish(raw) == raw)
    let inFlight = TranscriptionImprovementSession(improver: improver)
    let longText = String(repeating: "I think we should keep the original text and all technical details. ", count: 100)
    let finishing = Task { await inFlight.finish(longText) }
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await runtime.isProcessing), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    try #require(await runtime.isProcessing)
    inFlight.cancel()
    #expect(await finishing.value == longText)
    await improver.waitForPreparation()
    try #require(await improver.ready)
    let recovered = TranscriptionImprovementSession(improver: improver)
    #expect(await recovered.finish(fixtures[0].input) == fixtures[0].output)
    await improver.setEnabled(false)
}
