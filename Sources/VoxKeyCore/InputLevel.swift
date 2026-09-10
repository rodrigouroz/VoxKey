import Foundation

/// Content-free RMS metering performed on drained samples, never in the render callback.
public struct InputLevelMeter: Sendable {
    public static let silenceFloor: Float = -60
    public private(set) var level: Float = 0
    public private(set) var detectedAudio = false

    public init() {}

    public static func decibelsFS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return silenceFloor }
        let energy = samples.reduce(0.0) { $0 + ($1.isFinite ? Double($1) * Double($1) : 0) }
        guard energy > 0 else { return silenceFloor }
        return max(silenceFloor, min(0, Float(10 * log10(energy / Double(samples.count)))))
    }

    public static func normalized(decibels: Float) -> Float {
        guard decibels.isFinite else { return 0 }
        return min(1, max(0, (decibels - silenceFloor) / (-6 - silenceFloor)))
    }

    public static func segments(for level: Float) -> Int {
        guard level.isFinite else { return 0 }
        return Int(ceil(min(1, max(0, level)) * 6))
    }

    public mutating func consume(_ samples: [Float], sampleRate: Double) {
        guard !samples.isEmpty, sampleRate > 0 else { return }
        let db = Self.decibelsFS(samples)
        detectedAudio = detectedAudio || db > Self.silenceFloor
        let target = Self.normalized(decibels: db)
        let timeConstant = target > level ? 0.06 : 0.20
        let smoothing = Float(1 - exp(-Double(samples.count) / sampleRate / timeConstant))
        level += smoothing * (target - level)
    }
}

public enum InitialSilenceMessage {
    public static func text(detectedAudio: Bool) -> String {
        detectedAudio ? "No speech detected" : "No audio detected — check the microphone in Settings"
    }
}
