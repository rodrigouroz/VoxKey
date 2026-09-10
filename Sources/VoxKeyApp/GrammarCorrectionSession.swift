import Foundation

struct GrammarCorrectionCache: Sendable {
    var generation: Int? = nil
    var chunks: [String: String] = [:]
}

struct GrammarCorrectionResult: Sendable {
    let text: String
    let cache: GrammarCorrectionCache
}

/// One bounded worker per dictation. Only committed transcription enters it;
/// Whisper's prompt always retains the original, uncorrected words.
final class GrammarCorrectionSession: Sendable {
    private struct Request: Sendable { let text: String; let isFinal: Bool }
    private let continuation: AsyncStream<Request>.Continuation
    private let worker: Task<String?, Never>

    init(corrector: GrammarCorrector, enabled: Bool) {
        let stream = AsyncStream.makeStream(of: Request.self, bufferingPolicy: .bufferingNewest(1))
        continuation = stream.continuation
        worker = Task(priority: .utility) {
            await corrector.warmUp(enabledForSession: enabled)
            var cache = GrammarCorrectionCache()
            var latest: String?
            for await request in stream.stream {
                guard !Task.isCancelled else { return nil }
                // Prepare prospective long-text chunks before the transcript
                // crosses the input limit. Short final text still uses its full
                // qualified context; speculative edits never become the result.
                let result = await corrector.correctUsingCache(request.text, enabledForSession: enabled,
                    cache: cache, preserveShortContext: request.isFinal)
                latest = result.text
                // Retain only the current plan, never every growing prefix.
                cache = result.cache
            }
            return Task.isCancelled ? nil : latest
        }
    }

    deinit { cancel() }

    func observe(_ confirmedText: String) { continuation.yield(Request(text: confirmedText, isFinal: false)) }

    func finish(_ original: String) async -> String {
        continuation.yield(Request(text: original, isFinal: true))
        continuation.finish()
        let result = await worker.value
        return worker.isCancelled ? original : result ?? original
    }

    func cancel() {
        continuation.finish()
        worker.cancel()
    }
}
