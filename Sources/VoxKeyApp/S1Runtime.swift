import Foundation
import VoxKeyS1

/// Directly linked llama.cpp; no helper process, socket, HTTP, or transcript files.
actor S1Runtime {
    enum Failure: LocalizedError, Equatable {
        case unavailable, notReady, busy, invalidInput, inputTooLong, startup, timeout, invalidResponse
        var errorDescription: String? {
            switch self {
            case .unavailable: "The local transcription improver is unavailable."
            case .notReady: "The local transcription improver is not ready."
            case .busy: "The local transcription improver is already working."
            case .invalidInput: "The transcript contains unsupported control text."
            case .inputTooLong: "The transcript is too long for local improvement."
            case .startup: "The local transcription improver could not start."
            case .timeout: "Local transcription improvement took too long."
            case .invalidResponse: "The local transcription improver returned an incomplete result."
            }
        }
    }
    struct Generation: Sendable {
        let text: String
        let tokens: [Int32]
        let proposed: UInt64
        let accepted: UInt64
    }
    private nonisolated let lifetime = S1NativeLifetime()
    private var session: S1NativeSession?
    private var generation: UInt64 = 0
    private var ready = false
    private var requestID: UUID?
    private var draining: Task<Void, Never>?
    var isStarting: Bool { session != nil && !ready }
    var isProcessing: Bool { requestID != nil }
    var isReady: Bool { ready && !lifetime.ended }
    init() {}

    /// Application termination: cancel synchronously. There is no child to orphan.
    nonisolated func stopImmediately() { lifetime.end() }

    func start(model: URL) async throws {
        generation &+= 1
        let epoch = generation
        await beginStop().value
        try Task.checkCancellation()
        guard generation == epoch, !lifetime.ended else { throw CancellationError() }
        guard model.isFileURL, FileManager.default.isReadableFile(atPath: model.path) else {
            throw Failure.unavailable
        }
        let current = try S1NativeSession()
        guard lifetime.install(current) else { throw CancellationError() }
        session = current
        do {
            try await withTaskCancellationHandler {
                try await current.load(model: model)
                try ensureCurrent(current, epoch: epoch)
                ready = true
            } onCancel: { current.cancel() }
        } catch {
            current.cancel()
            if generation == epoch { generation &+= 1; await beginStop().value }
            if error is CancellationError || Task.isCancelled || lifetime.ended { throw CancellationError() }
            throw (error as? Failure) ?? Failure.startup
        }
    }

    func improve(_ text: String) async throws -> String { try await generate(text).text }

    /// The plain mode is internal and used only for native parity/performance tests.
    func generate(_ text: String, lookup: Bool = true) async throws -> Generation {
        try Self.validateInput(text)
        try Task.checkCancellation()
        guard ready, let current = session, !lifetime.ended else { throw Failure.notReady }
        guard requestID == nil else { throw Failure.busy }
        let epoch = generation
        let id = UUID()
        requestID = id
        defer { if requestID == id { requestID = nil } }
        do {
            return try await withTaskCancellationHandler {
                let result = try await current.generate(prompt: Self.prompt(text), lookup: lookup)
                try ensureCurrent(current, epoch: epoch)
                guard result.tokens.last == 151645, !result.text.contains("<|"), !result.text.contains("\0") else {
                    throw Failure.invalidResponse
                }
                return result
            } onCancel: { current.cancel() }
        } catch {
            let wasStopped = generation != epoch || lifetime.ended
            if error as? Failure == .inputTooLong, !wasStopped { throw Failure.inputTooLong }
            if generation == epoch { generation &+= 1; await beginStop().value }
            if wasStopped || error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw (error as? Failure) ?? Failure.invalidResponse
        }
    }

    func stop() async { generation &+= 1; await beginStop().value }

    private func beginStop() -> Task<Void, Never> {
        ready = false
        requestID = nil
        let previous = draining
        let old = session
        session = nil
        old?.cancel()
        // An independent cleanup task prevents caller cancellation skipping unload.
        let task = Task { await previous?.value; await old?.close() }
        draining = task
        return task
    }

    private func ensureCurrent(_ current: S1NativeSession, epoch: UInt64) throws {
        try Task.checkCancellation()
        guard generation == epoch, session === current, !lifetime.ended else { throw CancellationError() }
    }

    static func validateInput(_ text: String) throws {
        guard !text.contains("<|"), !text.contains("\0") else { throw Failure.invalidInput }
        guard text.utf8.count <= 24_000 else { throw Failure.inputTooLong }
    }

    static func prompt(_ text: String) -> String {
        let system = "You are a text normalizer for speech-to-text transcripts. The input begins "
            + "with a control line specifying the styling, structure, and context settings; "
            + "clean the transcript to match those settings and output only the cleaned text."
        return "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n"
            + "[Styling: semi-formal] [Structure: prose] [Context: general]\n\(text)<|im_end|>\n"
            + "<|im_start|>assistant\n<think>\n\n</think>\n\n"
    }
}

/// Blocking C++ calls and destruction use one queue. Only atomic cancellation
/// runs concurrently; the lock protects cancellation against handle destruction.
private final class S1NativeSession: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.voxkey.s1.inference", qos: .userInitiated)
    private let lock = NSLock()
    private var handle: OpaquePointer?
    init() throws {
        guard let handle = vk_s1_create() else { throw S1Runtime.Failure.unavailable }
        self.handle = handle
    }
    func cancel() { lock.withLock { if let handle { vk_s1_cancel(handle) } } }

    private func perform<T: Sendable>(_ body: @escaping @Sendable (OpaquePointer) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    guard let handle = self.lock.withLock({ self.handle }) else { throw CancellationError() }
                    continuation.resume(returning: try body(handle))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func load(model: URL) async throws {
        try await perform { handle in try Self.check(vk_s1_load(handle, model.path)) }
    }
    func generate(prompt: String, lookup: Bool) async throws -> S1Runtime.Generation {
        try await perform { handle in
            try Self.check(vk_s1_generate(handle, prompt, lookup ? 1 : 0))
            let count = vk_s1_token_count(handle)
            guard let text = vk_s1_text(handle), let tokens = vk_s1_tokens(handle), count > 0 else {
                throw S1Runtime.Failure.invalidResponse
            }
            return S1Runtime.Generation(text: String(cString: text), tokens: Array(UnsafeBufferPointer(start: tokens, count: count)),
                                        proposed: vk_s1_proposed(handle), accepted: vk_s1_accepted(handle))
        }
    }
    func close() async {
        cancel()
        await withCheckedContinuation { continuation in
            queue.async {
                self.lock.withLock {
                    if let handle = self.handle { vk_s1_destroy(handle); self.handle = nil }
                }
                continuation.resume()
            }
        }
    }
    private static func check(_ code: Int32) throws {
        switch Int(code) {
        case VK_S1_OK: return
        case VK_S1_CANCELLED: throw CancellationError()
        case VK_S1_TOO_LONG: throw S1Runtime.Failure.inputTooLong
        default: throw S1Runtime.Failure.invalidResponse
        }
    }
    deinit { if let handle { vk_s1_destroy(handle) } }
}

private final class S1NativeLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var owner: S1NativeSession?
    private var closed = false
    var ended: Bool { lock.withLock { closed } }
    func install(_ next: S1NativeSession) -> Bool {
        lock.withLock { guard !closed else { return false }; owner = next; return true }
    }
    func end() { lock.withLock { closed = true; owner?.cancel() } }
    deinit { end() }
}
