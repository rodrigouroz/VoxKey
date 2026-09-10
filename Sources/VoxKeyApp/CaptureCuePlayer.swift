import Foundation

@MainActor
final class CaptureCuePlayer {
    var enabled = true {
        didSet { if !enabled { finishPlayback() } }
    }
    private let output: any CaptureCueOutput
    private let timeout: Duration
    private var playbackID: UUID?
    private var completion: CheckedContinuation<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    init(output: any CaptureCueOutput = SystemCaptureCueOutput(), timeout: Duration = .seconds(1)) {
        self.output = output
        self.timeout = timeout
    }

    func playStart() async { await play(.start) }
    func playStop() async { await play(.stop) }

    func playRejection() async {
        // Rejection must not interrupt a session's start or stop confirmation.
        guard playbackID == nil else { return }
        await play(.rejection)
    }

    private func play(_ cue: CaptureCue) async {
        guard enabled, !Task.isCancelled else { return }
        finishPlayback()
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(); return }
                playbackID = id
                completion = continuation
                let accepted = output.play(cue) { [weak self] in
                    self?.finishPlayback(expectedID: id)
                }
                guard accepted else { finishPlayback(expectedID: id); return }
                guard playbackID == id else { return }
                timeoutTask = Task { [weak self, timeout] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.finishPlayback(expectedID: id)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishPlayback(expectedID: id) }
        }
    }

    private func finishPlayback(expectedID: UUID? = nil) {
        guard expectedID == nil || playbackID == expectedID else { return }
        // Stop output before resuming: even a timeout must not leak sound into capture.
        output.stop()
        playbackID = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        let continuation = completion
        completion = nil
        continuation?.resume()
    }
}
