import Foundation
@preconcurrency import WhisperKit
import VoxKeyCore

struct StreamingDecodeWindow {
    let samples: [Float]
}

/// Completed acoustic phrases plus an undecoded tail. Audio is retired
/// only at a measured pause, never at an estimated Whisper word timestamp.
struct StreamingTranscript {
    static let sampleRate = 16_000
    // An uninterrupted utterance can reach the product's ten-minute limit.
    // Preserve it rather than guessing a word boundary to satisfy a smaller cap.
    static let maximumBufferedSamples = 601 * sampleRate // includes the final hardware buffer at the time limit
    private static let minimumPhraseSamples = 2 * sampleRate
    private static let frameSamples = 320 // 20ms
    private static let quietFramesNeeded = 10 // 200ms below the conservative silence threshold

    private(set) var samples: [Float] = []
    private(set) var confirmedText = ""
    private(set) var consumedSamples = 0
    private(set) var decodeCount = 0
    private var scannedSamples = 0
    private var quietFrames = 0

    mutating func append(_ audio: [Float]) throws {
        guard samples.count + audio.count <= Self.maximumBufferedSamples else {
            throw TranscriptionError.streamingBacklog
        }
        samples.append(contentsOf: audio)
    }

    mutating func nextWindow(isFinal: Bool) -> StreamingDecodeWindow? {
        guard !samples.isEmpty else { return nil }
        // Release takes priority over searching for more phrase boundaries:
        // reconcile all remaining audio in one pass, including any internal pauses.
        if isFinal { return StreamingDecodeWindow(samples: samples) }
        if let boundary = nextPauseBoundary() {
            return StreamingDecodeWindow(samples: Array(samples.prefix(boundary)))
        }
        // Open-phrase predictions cannot retire audio and are not displayed.
        // Starting one here can make release wait for two consecutive decodes.
        return nil
    }

    mutating func accept(_ text: String, window: StreamingDecodeWindow, decoded: Bool = true) {
        if decoded { decodeCount += 1 }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            if !confirmedText.isEmpty { confirmedText += " " }
            confirmedText += text
        }
        samples = Array(samples.dropFirst(window.samples.count))
        consumedSamples += window.samples.count
        scannedSamples = 0
        quietFrames = 0
    }

    var outcome: TranscriptionOutcome {
        confirmedText.isEmpty ? .noSpeech : .final(confirmedText)
    }

    private mutating func nextPauseBoundary() -> Int? {
        let detector = EnergyVAD(sampleRate: Self.sampleRate, frameLength: 0.02,
                                 frameOverlap: 0, energyThreshold: 0.003)
        let completeEnd = samples.count / Self.frameSamples * Self.frameSamples
        guard completeEnd > scannedSamples else { return nil }
        let activity = detector.voiceActivity(in: Array(samples[scannedSamples..<completeEnd]))
        for voiced in activity {
            scannedSamples += Self.frameSamples
            quietFrames = voiced ? 0 : quietFrames + 1
            // Leave 100ms of the quiet span on each side of the cut. The same
            // samples never occur in two decoded phrases, so repeats stay intact.
            let boundary = scannedSamples - Self.frameSamples * (Self.quietFramesNeeded / 2)
            if quietFrames >= Self.quietFramesNeeded, boundary >= Self.minimumPhraseSamples {
                return boundary
            }
        }
        return nil
    }
}
