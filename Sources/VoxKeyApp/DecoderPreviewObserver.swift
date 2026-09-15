import Foundation
import Synchronization
@preconcurrency import WhisperKit

struct DecoderPreview: Sendable {
    let decodeIndex: Int
    let windowIndex: Int
    let tokens: [Int]
    let revision: Int
    let text: String?

    init(decodeIndex: Int, windowIndex: Int, tokens: [Int], revision: Int = 0, text: String? = nil) {
        self.decodeIndex = decodeIndex
        self.windowIndex = windowIndex
        self.tokens = tokens
        self.revision = revision
        self.text = text
    }
}

/// Orders WhisperKit's detached callbacks without waiting for the UI. Only an
/// explicitly cancelled speculative decode may request an early stop.
final class DecoderPreviewObserver: Sendable {
    private struct State {
        var closed = false
        var stopRequested = false
        var window = -1
        var attemptStart: Double = 0
        var tokenCount = -1
    }
    private let state = Mutex(State())
    private let decodeIndex: Int
    private let revision: Int
    private let emit: @Sendable (DecoderPreview) -> Void

    init(decodeIndex: Int, revision: Int = 0, emit: @escaping @Sendable (DecoderPreview) -> Void) {
        self.decodeIndex = decodeIndex
        self.revision = revision
        self.emit = emit
    }

    func observe(_ progress: TranscriptionProgress) -> Bool? {
        state.withLock { state -> Bool? in
            if state.stopRequested { return false }
            guard !state.closed, progress.windowId >= state.window else { return nil }
            // firstTokenTime identifies a decoding attempt, including fallbacks.
            // Before the first token, WhisperKit uses greatestFiniteMagnitude.
            let attempt = progress.timings.firstTokenTime == .greatestFiniteMagnitude
                ? 0 : progress.timings.firstTokenTime
            if progress.windowId > state.window {
                state.window = progress.windowId
                state.attemptStart = 0
                state.tokenCount = -1
            }
            guard attempt >= state.attemptStart else { return nil }
            if attempt > state.attemptStart {
                state.attemptStart = attempt
                state.tokenCount = -1
            }
            guard progress.tokens.count > state.tokenCount else { return nil }
            state.tokenCount = progress.tokens.count
            emit(DecoderPreview(decodeIndex: decodeIndex, windowIndex: progress.windowId, tokens: progress.tokens, revision: revision))
            return nil
        }
    }

    func close() { state.withLock { $0.closed = true } }

    func cancelDecoding() {
        state.withLock { $0.closed = true; $0.stopRequested = true }
    }

    static func generatedTokens(_ tokens: [Int], startOfTranscript: Int, specialTokenBegin: Int) -> [Int] {
        guard let start = tokens.lastIndex(of: startOfTranscript) else { return [] }
        // Vocabulary and preceding-text prompts occur before startOfTranscript.
        return tokens[(start + 1)...].filter { $0 < specialTokenBegin }
    }
}
