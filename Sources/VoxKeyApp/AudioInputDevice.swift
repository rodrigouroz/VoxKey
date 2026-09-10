@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio

/// The microphone/AVAudioEngine boundary. Owned exclusively by AudioCaptureService.
protocol AudioInputDevice {
    var sampleRate: Double { get }
    var isAvailable: Bool { get }
    func start(write: @escaping @Sendable (UnsafePointer<Float>, Int) -> Void) throws
    func stop()
}

extension AudioInputDevice {
    var isAvailable: Bool { true }
}

final class SystemAudioInputDevice: AudioInputDevice {
    private let engine = AVAudioEngine()
    private let format: AVAudioFormat
    private var tapInstalled = false
    private let deviceID: AudioDeviceID
    var isAvailable: Bool { SystemAudioInputDevices.isAlive(deviceID) && engine.isRunning }

    var sampleRate: Double { format.sampleRate }

    init(deviceID: AudioDeviceID? = nil) throws {
        guard var resolvedID = deviceID ?? SystemAudioInputDevices.defaultInputID(),
              SystemAudioInputDevices.isAlive(resolvedID), let unit = engine.inputNode.audioUnit else {
            throw AudioCaptureError.inputUnavailable
        }
        // Resolve even the default explicitly: a system preference change must not
        // migrate an open capture to a different microphone.
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                                   0, &resolvedID, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
            throw AudioCaptureError.inputUnavailable
        }
        self.deviceID = resolvedID
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0, format.commonFormat == .pcmFormatFloat32 else {
            throw AudioCaptureError.unsupportedInputFormat
        }
        self.format = format
    }

    func start(write: @escaping @Sendable (UnsafePointer<Float>, Int) -> Void) throws {
        engine.inputNode.installTap(onBus: 0, bufferSize: 2_048, format: format) { buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            write(channel, Int(buffer.frameLength))
        }
        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            throw AudioCaptureError.engineStartFailed(error)
        }
    }

    func stop() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
    }
}
