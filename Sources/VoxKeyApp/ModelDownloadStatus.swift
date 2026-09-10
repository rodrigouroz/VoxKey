import Foundation

/// WhisperKit's fraction weights files equally, so it cannot support a byte-based ETA.
struct ModelDownloadStatus: Equatable {
    let fraction: Double
    let elapsedSeconds: Int

    init(fraction: Double, elapsed: TimeInterval) {
        self.fraction = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        elapsedSeconds = elapsed.isFinite ? Int(min(max(elapsed, 0), 31_536_000)) : 0
    }

    var title: String {
        if fraction == 0 { return "Starting download…" }
        if fraction == 1 { return "Finishing download…" }
        return "Downloading… \(Int(fraction * 100))%"
    }

    var detail: String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        let elapsed = minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"
        return "\(elapsed) elapsed · Time remaining unavailable"
    }

    var message: String { "\(title) \(detail)" }
    var isIndeterminate: Bool { fraction == 0 || fraction == 1 }
}
