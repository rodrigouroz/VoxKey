@preconcurrency import AVFoundation
import Foundation
import CoreAudio
import VoxKeyAudioRing
import VoxKeyCore

enum AudioCaptureError: Error, LocalizedError {
    case alreadyCapturing
    case inputUnavailable
    case unsupportedInputFormat
    case ringAllocationFailed
    case engineStartFailed(Error)
    case audioOverflow

    var errorDescription: String? {
        switch self {
        case .alreadyCapturing: "A dictation is already capturing audio."
        case .inputUnavailable: "The system input device is unavailable."
        case .unsupportedInputFormat: "The system input format is unsupported."
        case .ringAllocationFailed: "VoxKey could not allocate its volatile audio buffer."
        case let .engineStartFailed(error): "Audio capture could not start: \(error.localizedDescription)"
        case .audioOverflow: "Audio processing could not keep up without dropping speech."
        }
    }
}

private final class AudioRingHandle: @unchecked Sendable {
    private let pointer: OpaquePointer

    init(capacity: Int) throws {
        guard let pointer = vk_audio_ring_create(capacity) else {
            throw AudioCaptureError.ringAllocationFailed
        }
        self.pointer = pointer
    }

    deinit {
        vk_audio_ring_destroy(pointer)
    }

    func write(_ samples: UnsafePointer<Float>, count: Int) -> Bool {
        vk_audio_ring_write(pointer, samples, count)
    }

    func read(maximumCount: Int) -> [Float] {
        let requested = min(maximumCount, Int(vk_audio_ring_available(pointer)))
        guard requested > 0 else { return [] }
        var output = Array(repeating: Float.zero, count: requested)
        let actual = output.withUnsafeMutableBufferPointer { buffer in
            vk_audio_ring_read(pointer, buffer.baseAddress!, requested)
        }
        if actual < output.count {
            output.removeLast(output.count - actual)
        }
        return output
    }

    var availableCount: Int { Int(vk_audio_ring_available(pointer)) }
    var overflowed: Bool { vk_audio_ring_overflowed(pointer) }
}

actor AudioCaptureService {
    private var audioSignal = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    var audioUpdates: AsyncStream<Void> { audioSignal.stream }
    private let makeInput: @Sendable (AudioDeviceID?) throws -> any AudioInputDevice
    private var input: (any AudioInputDevice)?
    private var ring: AudioRingHandle?
    private var drainTask: Task<Void, Never>?
    private var rawSamples: [Float] = []
    private var speechStartSamples: [Float] = []
    private var speechStarted = false
    private var pendingOverflow = false
    private var closing = false
    private var sampleRate: Double = 0
    private var capturing = false
    private var levelMeter = InputLevelMeter()
    func inputLevel() -> Float { levelMeter.level }
    func detectedAudio() -> Bool { levelMeter.detectedAudio }

    init(makeInput: @escaping @Sendable (AudioDeviceID?) throws -> any AudioInputDevice = { try SystemAudioInputDevice(deviceID: $0) }) {
        self.makeInput = makeInput
    }

    static func microphoneAuthorized() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestMicrophonePermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    private(set) var usedDefaultFallback = false

    func inputIsAvailable() -> Bool { input?.isAvailable ?? false }

    func start(preferredUID: String? = nil) throws {
        try start(selection: SystemAudioInputDevices.read().selection(for: preferredUID))
    }

    func start(selection: AudioInputSelection) throws {
        guard !capturing, !closing else { throw AudioCaptureError.alreadyCapturing }

        levelMeter = InputLevelMeter()
        usedDefaultFallback = selection.usedDefaultFallback
        let input: any AudioInputDevice
        do {
            input = try makeInput(selection.deviceID)
        } catch AudioCaptureError.inputUnavailable where selection.deviceID != nil {
            // The pinned device may vanish after enumeration but before opening.
            input = try makeInput(nil)
            usedDefaultFallback = true
        }
        let ring = try AudioRingHandle(capacity: Int(input.sampleRate * 5))
        audioSignal.continuation.finish()
        audioSignal = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        rawSamples.removeAll(keepingCapacity: true)
        speechStartSamples.removeAll(keepingCapacity: false)
        speechStarted = false
        pendingOverflow = false
        sampleRate = input.sampleRate
        capturing = true

        do {
            try input.start { samples, count in
                _ = ring.write(samples, count: count)
            }
        } catch {
            input.stop()
            capturing = false
            throw error
        }

        self.input = input
        self.ring = ring
        drainTask = Task { [weak self] in
            await self?.drainUntilCancelled()
        }
    }

    func stop() async throws -> CapturedAudio {
        try await finish()
        return try takePendingAudio().audio
    }

    /// Close the microphone without consuming the tail owned by the transcription worker.
    func finish() async throws {
        guard capturing else { return }

        capturing = false
        closing = true
        defer { closing = false }
        input?.stop()
        input = nil

        drainTask?.cancel()
        _ = await drainTask?.value
        drainTask = nil
        drainAvailableSamples()

        pendingOverflow = pendingOverflow || (ring?.overflowed ?? false)
        ring = nil
        speechStartSamples.removeAll(keepingCapacity: false)
        audioSignal.continuation.finish()
        if pendingOverflow { throw AudioCaptureError.audioOverflow }
    }

    /// One consumer drains each sample exactly once. Never drop old speech to catch up.
    func takePendingAudio() throws -> (audio: CapturedAudio, isFinal: Bool) {
        drainAvailableSamples()
        guard !pendingOverflow, ring?.overflowed != true else { throw AudioCaptureError.audioOverflow }
        let result = CapturedAudio(samples: rawSamples, sampleRate: sampleRate, overflowed: false)
        rawSamples = []
        return (result, !capturing && !closing)
    }

    func cancel() async {
        capturing = false
        closing = true
        defer { closing = false }
        input?.stop()
        input = nil
        drainTask?.cancel()
        _ = await drainTask?.value
        drainTask = nil
        ring = nil
        rawSamples.removeAll(keepingCapacity: false)
        speechStartSamples.removeAll(keepingCapacity: false)
        speechStarted = false
        pendingOverflow = false
        audioSignal.continuation.finish()
    }

    func speechStartStatus() -> SpeechStartStatus {
        guard capturing else { return .silent }
        // Drain pending hardware buffers before the deadline decision. Analysis
        // runs on this actor, never in the realtime microphone callback.
        drainAvailableSamples()
        if speechStarted { return .speech }
        let status = SpeechActivityGate.startStatus(in: speechStartSamples, sampleRate: Int(sampleRate))
        if status == .speech {
            speechStarted = true
            speechStartSamples.removeAll(keepingCapacity: false)
        }
        return status
    }

    private func drainUntilCancelled() async {
        while !Task.isCancelled {
            drainAvailableSamples()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func drainAvailableSamples() {
        guard let ring else { return }
        while ring.availableCount > 0 {
            let chunk = ring.read(maximumCount: 8_192)
            guard !chunk.isEmpty else { break }
            levelMeter.consume(chunk, sampleRate: sampleRate)
            // The hardware ring and pending queue have independent bounds. A slow
            // decoder may leave a backlog here while the realtime ring stays empty.
            if rawSamples.count + chunk.count > Int(sampleRate * 30) {
                pendingOverflow = true
            } else if !pendingOverflow {
                rawSamples.append(contentsOf: chunk)
            }
            if !speechStarted {
                // Initial-speech detection must survive the transcription worker
                // draining audio. The production deadline is 3s plus 300ms grace.
                let remaining = max(0, Int(sampleRate * 4) - speechStartSamples.count)
                speechStartSamples.append(contentsOf: chunk.prefix(remaining))
            }
        }
        if pendingOverflow || ring.overflowed || rawSamples.count >= Int(sampleRate / 10) {
            // This stream carries wakeups, never audio. Coalescing notifications
            // cannot lose samples, and finish wakes the worker immediately.
            audioSignal.continuation.yield(())
        }
    }
}
