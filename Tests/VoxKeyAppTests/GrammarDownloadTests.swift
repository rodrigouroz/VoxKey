import Foundation
import Testing
import VoxKeyCore
@testable import VoxKeyApp

/// Only the HTTP boundary is simulated. Transfer, cancellation, validation and
/// filesystem ownership exercise the production implementation.
private final class GrammarHTTPFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let pending = request.value(forHTTPHeaderField: "X-VoxKey-Test-Pending") == "1"
        let status = !pending && url.path.hasSuffix("model.safetensors") ? 503 : 200
        let data = Data(repeating: 0x61, count: 16_384)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "16384"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        if !pending, url.path != "/cancel" { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {}
}

private func grammarHTTPConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [GrammarHTTPFixture.self]
    return configuration
}

@MainActor @Test(.timeLimit(.minutes(1)))
func pendingGrammarDownloadKeepsDictationReadyAndPassesTranscriptsThrough() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("grammar-pending-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = grammarHTTPConfiguration()
    configuration.httpAdditionalHeaders = ["X-VoxKey-Test-Pending": "1"]
    let corrector = GrammarCorrector(store: GrammarModelStore(root: root, session: URLSession(configuration: configuration)))
    let coordinator = SessionCoordinator(initialState: SessionStateMachine(phase: .ready), grammarCorrector: corrector)

    // This must return while the real installer is waiting for more HTTP bytes.
    // Otherwise the app's trigger, which awaits the preference update, would stall.
    await coordinator.setGrammarCorrectionEnabled(true, download: true)
    for await state in corrector.updates {
        if case let .downloading(fraction) = state, fraction > 0 { break }
        try #require(state != .unavailable)
    }
    #expect(await coordinator.currentSnapshot().phase == .ready)
    for transcript in ["Okay, make sense, thanks.", "The build is ready.", "Call me tomorrow."] {
        #expect(await corrector.correct(transcript, enabledForSession: true) == transcript)
    }
    #expect(await !corrector.isLoaded)

    await coordinator.setGrammarCorrectionEnabled(false)
    #expect(await coordinator.currentSnapshot().phase == .ready)
    #expect(await corrector.correct("Okay, make sense, thanks.", enabledForSession: true) == "Okay, make sense, thanks.")
}

@Test func grammarDownloadEnforcesItsByteLimit() async throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let transfer = GrammarAssetDownload(destination: temporary, limit: 8) { _ in }
    await #expect(throws: GrammarInstallationError.invalidAsset) {
        try await transfer.run(from: URL(string: "https://grammar.invalid/oversize")!, configuration: grammarHTTPConfiguration())
    }
}

@Test func grammarDownloadCancellationCompletesAndReleasesTheRequest() async throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let progress = AsyncStream.makeStream(of: Int.self, bufferingPolicy: .bufferingNewest(1))
    let transfer = GrammarAssetDownload(destination: temporary, limit: 16_384) { progress.continuation.yield($0) }
    let task = Task { try await transfer.run(from: URL(string: "https://grammar.invalid/cancel")!, configuration: grammarHTTPConfiguration()) }
    defer { task.cancel(); progress.continuation.finish() }
    var iterator = progress.stream.makeAsyncIterator()
    #expect(await iterator.next() != nil)
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func failedGrammarHTTPResponseNeverActivatesAnInstallation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("grammar-http-failure-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = GrammarModelStore(root: root, session: URLSession(configuration: grammarHTTPConfiguration()))
    await #expect(throws: GrammarInstallationError.invalidAsset) { try await store.prepare(download: true) }
    await #expect(throws: GrammarInstallationError.downloadRequired) { try await store.prepare(download: false) }
    let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
    #expect(!files.contains { $0.lastPathComponent == "receipt" || $0.lastPathComponent.hasPrefix("partial-") })
}
