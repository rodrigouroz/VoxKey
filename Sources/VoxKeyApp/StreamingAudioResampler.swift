@preconcurrency import AVFoundation
import Synchronization
import VoxKeyCore

/// One converter per dictation preserves filter history and fractional sample
/// positions across microphone chunks. Used only by the transcription worker.
final class StreamingAudioResampler {
    private var converter: AVAudioConverter?
    private var sampleRate: Double?

    func append(_ capture: CapturedAudio, isFinal: Bool) throws -> [Float] {
        guard capture.sampleRate.isFinite, capture.sampleRate > 0, !capture.overflowed,
              capture.samples.allSatisfy(\.isFinite) else { throw TranscriptionError.invalidAudio }
        if let sampleRate, sampleRate != capture.sampleRate { throw TranscriptionError.invalidAudio }
        sampleRate = capture.sampleRate
        if capture.sampleRate == WhisperTranscriber.targetSampleRate { return capture.samples }

        if converter == nil {
            guard let input = AVAudioFormat(standardFormatWithSampleRate: capture.sampleRate, channels: 1),
                  let output = AVAudioFormat(standardFormatWithSampleRate: WhisperTranscriber.targetSampleRate, channels: 1),
                  let candidate = AVAudioConverter(from: input, to: output) else {
                throw TranscriptionError.resamplingFailed
            }
            converter = candidate
        }
        guard let converter,
              let input = AVAudioPCMBuffer(pcmFormat: converter.inputFormat,
                                          frameCapacity: AVAudioFrameCount(max(1, capture.samples.count))),
              let channel = input.floatChannelData?[0] else { throw TranscriptionError.resamplingFailed }
        input.frameLength = AVAudioFrameCount(capture.samples.count)
        capture.samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel.update(from: base, count: source.count) }
        }
        let capacity = AVAudioFrameCount((Double(capture.samples.count) * 16_000 / capture.sampleRate).rounded(.up)) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            throw TranscriptionError.resamplingFailed
        }
        let supplied = Mutex(false)
        var samples: [Float] = []
        while true {
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                let needsInput = supplied.withLock { used in
                    guard !used, input.frameLength > 0 else { return false }
                    used = true
                    return true
                }
                if needsInput {
                    inputStatus.pointee = .haveData
                    return input
                }
                inputStatus.pointee = isFinal ? .endOfStream : .noDataNow
                return nil
            }
            guard status != .error, error == nil, let channel = output.floatChannelData?[0] else {
                throw TranscriptionError.resamplingFailed
            }
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            if status != .haveData { return samples }
        }
    }
}
