#if DEBUG && VOXKEY_LOCAL_DIAGNOSTICS && !VOXKEY_RELEASE
import Foundation
import Testing
@testable import VoxKeyApp

@Test func transcriptionTracesRequireOptInAndInvalidatePendingWrites() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    let store = TranscriptionDiagnostics(directory: root, defaults: defaults)
    #expect(store.begin(id: UUID(), raw: "Do not record this.") == nil)
    #expect(!FileManager.default.fileExists(atPath: root.path))
    store.setEnabled(true)
    let old = try #require(store.begin(id: UUID(), raw: "The report is ready."))
    store.setEnabled(false)
    store.setEnabled(true)
    store.save(old)
    #expect(!FileManager.default.fileExists(atPath: root.path))
    let pending = try #require(store.begin(id: UUID(), raw: "A pending trace."))
    try store.deleteAll()
    store.save(pending)
    #expect(!FileManager.default.fileExists(atPath: root.path))
}

@Test func transcriptionTracesPersistExactStagesWithPrivatePermissionsAndBoundedRetention() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    let store = TranscriptionDiagnostics(directory: root, defaults: defaults, maximumRecords: 2)
    store.setEnabled(true)
    var last: TranscriptionTrace?
    for index in 0..<3 {
        var trace = try #require(store.begin(id: UUID(), raw: "Raw \(index): The report is ready.\nCafé"))
        trace.s1 = "The report was ready."
        trace.grammarInput = trace.s1
        trace.gector = trace.s1
        trace.output = trace.s1!
        trace.status = "completed"
        store.save(trace)
        last = trace
    }
    let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    #expect(files.count == 2)
    let lastTrace = try #require(last)
    let file = root.appendingPathComponent("\(lastTrace.id.uuidString)-improvement.json")
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let saved = try decoder.decode(TranscriptionTrace.self, from: Data(contentsOf: file))
    #expect(saved.raw == lastTrace.raw && saved.s1 == lastTrace.s1 && saved.output == lastTrace.output)
    #expect(saved.status == "completed")
    #expect((try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    for old in files {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 86_400)], ofItemAtPath: old.path)
    }
    store.save(store.begin(id: UUID(), raw: "Fresh record."))
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 1)
    store.save(store.begin(id: UUID(), raw: String(repeating: "x", count: 256_001)))
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 1)
    try store.deleteAll()
    #expect(!FileManager.default.fileExists(atPath: root.path))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VOXKEY_IMPROVEMENT_TEST_MODEL"] != nil))
func transcriptionTraceCapturesRealModelsAndFallback() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    let store = TranscriptionDiagnostics(directory: root, defaults: defaults)
    store.setEnabled(true)
    let env = ProcessInfo.processInfo.environment
    let improver = TranscriptionImprover(grammar: GrammarCorrector(assets: URL(fileURLWithPath: try #require(env["VOXKEY_GRAMMAR_TEST_ASSETS"]))),
        model: URL(fileURLWithPath: try #require(env["VOXKEY_IMPROVEMENT_TEST_MODEL"])))
    await improver.setDiagnostics(store)
    await improver.setEnabled(true)
    await improver.waitForPreparation()
    try #require(await improver.ready)
    let id = UUID()
    let raw = "These is my files."
    let output = await improver.improve(raw, generation: await improver.generation, requestID: id)
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let trace = try decoder.decode(TranscriptionTrace.self, from: Data(contentsOf: root.appendingPathComponent("\(id.uuidString)-improvement.json")))
    #expect(trace.raw == raw && trace.output == output)
    #expect(trace.status == "completed")
    #expect(trace.s1 != nil && trace.gector != nil && trace.grammarInput != nil)
    #expect(try #require(trace.s1Milliseconds) > 0)
    #expect(try #require(trace.gectorMilliseconds) > 0)
    let fallbackID = UUID()
    let invalid = "Keep <|im_start|> exactly."
    #expect(await improver.improve(invalid, generation: await improver.generation, requestID: fallbackID) == invalid)
    let fallback = try decoder.decode(TranscriptionTrace.self, from: Data(contentsOf: root.appendingPathComponent("\(fallbackID.uuidString)-improvement.json")))
    #expect(fallback.status.contains("invalidInput") && fallback.s1 == nil && fallback.output == invalid)
    await improver.setEnabled(false)
}
#endif
