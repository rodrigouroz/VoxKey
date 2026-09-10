@preconcurrency import AVFoundation

enum CaptureCue: String, CaseIterable, Sendable {
    case start, stop, rejection

    var url: URL? { url(in: .main) }

    func url(in application: Bundle) -> URL? {
        if application.bundleURL.pathExtension == "app" {
            // build-app.sh installs SwiftPM resources here. Never fall back to the
            // developer checkout (or trap in Bundle.module) for a distributed app.
            guard let resources = application.resourceURL,
                  let bundle = Bundle(url: resources.appendingPathComponent("VoxKey_VoxKeyApp.bundle")) else { return nil }
            return bundle.url(forResource: rawValue, withExtension: "wav")
        }
        return Bundle.module.url(forResource: rawValue, withExtension: "wav")
    }
}

/// The speaker/AVAudioPlayer boundary. Tests substitute only the hardware playback callbacks.
@MainActor
protocol CaptureCueOutput: AnyObject {
    func play(_ cue: CaptureCue, completion: @escaping @MainActor @Sendable () -> Void) -> Bool
    func stop()
}

@MainActor
final class SystemCaptureCueOutput: NSObject, CaptureCueOutput, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var completion: (@MainActor @Sendable () -> Void)?

    func play(_ cue: CaptureCue, completion: @escaping @MainActor @Sendable () -> Void) -> Bool {
        stop()
        guard let url = cue.url, let player = try? AVAudioPlayer(contentsOf: url) else { return false }
        self.player = player
        self.completion = completion
        player.delegate = self
        guard player.play() else {
            stop()
            return false
        }
        return true
    }

    func stop() {
        player?.stop()
        player?.delegate = nil
        player = nil
        completion = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        completePlayback(ObjectIdentifier(player))
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        completePlayback(ObjectIdentifier(player))
    }

    private nonisolated func completePlayback(_ identity: ObjectIdentifier) {
        Task { @MainActor [weak self] in
            guard let self, let player = self.player, ObjectIdentifier(player) == identity else { return }
            let callback = completion
            stop()
            callback?()
        }
    }
}
