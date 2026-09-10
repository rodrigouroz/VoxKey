import Foundation
import Testing
@testable import VoxKeyApp

@Test
func silenceDoesNotReachTheTranscriptionModel() {
    let samples = Array(repeating: Float.zero, count: 16_000)

    #expect(!SpeechActivityGate.containsSpeech(in: samples))
}

@Test
func lowLevelBackgroundSignalDoesNotCountAsSpeech() {
    let samples = Array(repeating: Float(0.004), count: 16_000)

    #expect(!SpeechActivityGate.containsSpeech(in: samples))
}

@Test
func briefSeparatedNoisesDoNotCountAsSpeech() {
    var samples = Array(repeating: Float.zero, count: 16_000)
    samples.replaceSubrange(800..<1_120, with: repeatElement(Float(0.2), count: 320))
    samples.replaceSubrange(14_400..<14_720, with: repeatElement(Float(0.2), count: 320))

    #expect(!SpeechActivityGate.containsSpeech(in: samples))
}

@Test
func speechLikeSignalReachesTheTranscriptionModel() {
    let sampleRate = 16_000
    let leadingSilence = Array(repeating: Float.zero, count: sampleRate / 5)
    let voiced = (0..<(sampleRate / 2)).map { index in
        Float(sin(2 * Double.pi * 220 * Double(index) / Double(sampleRate))) * 0.08
    }
    let trailingSilence = Array(repeating: Float.zero, count: sampleRate / 5)

    #expect(SpeechActivityGate.containsSpeech(in: leadingSilence + voiced + trailingSilence))
}
