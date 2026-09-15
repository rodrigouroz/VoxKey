import Foundation

/// Copies only recent unfinished audio. This never accepts text or retires audio
/// from StreamingTranscript; the ordinary phrase decoder remains authoritative.
struct ProvisionalDecodeSchedule {
    private var lastAudioEnd = 0
    private var lastStarted: ContinuousClock.Instant?

    mutating func nextSamples(in transcript: StreamingTranscript, now: ContinuousClock.Instant = .now) -> [Float]? {
        let rate = StreamingTranscript.sampleRate
        let audioEnd = transcript.consumedSamples + transcript.samples.count
        guard transcript.samples.count >= rate,
              audioEnd - lastAudioEnd >= rate / 2,
              lastStarted.map({ $0.duration(to: now) >= .milliseconds(700) }) ?? true else { return nil }
        lastStarted = now
        lastAudioEnd = audioEnd
        // Do not keep predicting old speech while the microphone is quiet.
        guard SpeechActivityGate.containsSpeech(in: Array(transcript.samples.suffix(rate / 2))) else { return nil }
        return Array(transcript.samples.suffix(8 * rate))
    }
}
