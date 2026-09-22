import Foundation
@preconcurrency import WhisperKit

/// Copies only recent unfinished audio. This never accepts text or retires audio
/// from StreamingTranscript; the ordinary phrase decoder remains authoritative.
struct ProvisionalDecodeSchedule {
    private var lastAudioEnd = 0
    private var lastStarted: ContinuousClock.Instant?
    private var scannedAudioEnd = 0
    private var speechFrames = 0
    private var quietFrames = 0
    private var lastVoicedEnd = 0
    private var pauseArmed = false
    private var pendingPauseEnd: Int?

    mutating func nextSamples(in transcript: StreamingTranscript, now: ContinuousClock.Instant = .now,
                              decoderAvailable: Bool = true) -> [Float]? {
        let rate = StreamingTranscript.sampleRate
        let audioEnd = transcript.consumedSamples + transcript.samples.count
        observePauses(in: transcript)
        // Observe every capture batch, including while inference is busy. Keep
        // one catch-up request, never a queue of obsolete audio snapshots.
        guard decoderAvailable,
              lastStarted.map({ $0.duration(to: now) >= .milliseconds(700) }) ?? true else { return nil }
        if pendingPauseEnd != nil {
            // If speech resumed, include it. If still quiet, retain the last
            // words plus 300ms instead of decoding an ever-growing silence tail.
            let end = min(audioEnd, lastVoicedEnd + 3 * rate / 10) - transcript.consumedSamples
            pendingPauseEnd = nil
            lastStarted = now
            lastAudioEnd = audioEnd
            return Array(transcript.samples[max(0, end - 8 * rate)..<end])
        }
        let windowSamples = min(transcript.samples.count, 8 * rate)
        // Keep the first preview quick, then amortize longer windows over fresh
        // audio. At least a quarter of each requested window must be new, bounding
        // continuous-speech speculative audio to 4x captured audio. Retain the full
        // context rather than clipping words to make each model call cheaper.
        let minimumNewSamples = max(rate / 2, (windowSamples + 3) / 4)
        guard transcript.samples.count >= rate,
              audioEnd - lastAudioEnd >= minimumNewSamples else { return nil }
        lastStarted = now
        lastAudioEnd = audioEnd
        // Do not keep predicting old speech while the microphone is quiet.
        guard SpeechActivityGate.containsSpeech(in: Array(transcript.samples.suffix(rate / 2))) else { return nil }
        return Array(transcript.samples.suffix(windowSamples))
    }

    private mutating func observePauses(in transcript: StreamingTranscript) {
        let frameSamples = StreamingTranscript.sampleRate / 10
        let quietFramesNeeded = 3
        if scannedAudioEnd < transcript.consumedSamples {
            scannedAudioEnd = transcript.consumedSamples
            speechFrames = 0
            quietFrames = 0
        }
        if lastVoicedEnd <= transcript.consumedSamples { pauseArmed = false }
        if let pendingPauseEnd, pendingPauseEnd - quietFramesNeeded * frameSamples <= transcript.consumedSamples {
            self.pendingPauseEnd = nil
        }
        let offset = scannedAudioEnd - transcript.consumedSamples
        let count = (transcript.samples.count - offset) / frameSamples * frameSamples
        if count > 0 {
            // Match preview speech detection, not the stricter threshold used
            // to retire authoritative audio. Each complete frame is scanned once.
            let detector = EnergyVAD(sampleRate: StreamingTranscript.sampleRate,
                frameLength: 0.1, frameOverlap: 0, energyThreshold: 0.01)
            for voiced in detector.voiceActivity(in: Array(transcript.samples[offset..<(offset + count)])) {
                scannedAudioEnd += frameSamples
                if voiced {
                    speechFrames += 1
                    quietFrames = 0
                    lastVoicedEnd = scannedAudioEnd
                    if speechFrames >= 2 { pauseArmed = true }
                } else {
                    speechFrames = 0
                    quietFrames += 1
                    if pauseArmed, quietFrames == quietFramesNeeded {
                        pendingPauseEnd = scannedAudioEnd
                        pauseArmed = false
                    }
                }
            }
        }
    }
}
