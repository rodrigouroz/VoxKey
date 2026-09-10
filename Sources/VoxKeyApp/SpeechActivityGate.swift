import Foundation
@preconcurrency import WhisperKit

enum SpeechStartStatus: Equatable, Sendable {
    case silent
    case possibleSpeech
    case speech
}

enum SpeechActivityGate {
    static let sampleRate = 16_000

    static func containsSpeech(in samples: [Float]) -> Bool {
        startStatus(in: samples) == .speech
    }

    static func startStatus(in samples: [Float], sampleRate: Int = sampleRate) -> SpeechStartStatus {
        guard !samples.isEmpty, sampleRate > 0 else { return .silent }

        let detector = EnergyVAD(
            sampleRate: sampleRate,
            frameLength: 0.1,
            frameOverlap: 0,
            energyThreshold: 0.01
        )
        let activity = detector.voiceActivity(in: samples)
        if zip(activity, activity.dropFirst()).contains(where: { current, next in
            current && next
        }) { return .speech }
        // Give an onset near the deadline one short grace period. A transient
        // sound does not buy an entire recording session or repeated extensions.
        return activity.suffix(2).contains(true) ? .possibleSpeech : .silent
    }
}
