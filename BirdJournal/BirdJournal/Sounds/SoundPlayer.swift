import AVFAudio
import Foundation
import LensSession
import OSLog

/// Plays one reference clip at a time (issue #41). `onFinish` is told when a clip plays to its end or fails part-way,
/// never after `stop()`.
@MainActor
protocol SoundPlayer: AnyObject {
    var isPlaying: Bool { get }
    var onFinish: (() -> Void)? { get set }
    /// Starts `url` from the beginning, replacing any clip playing.
    func play(_ url: URL) throws
    func stop()
}

/// The audio session as a clip needs it when nothing else holds it: the glasses run has none (its audio arrives on
/// the camera stream), and the Field Guide may play with no run at all.
@MainActor
protocol PlaybackAudioSession: AnyObject {
    func activate() async throws
    func deactivate()
    /// Whether the session's output is a Bluetooth A2DP device (the glasses' speakers), read as a clip starts.
    var routesToBluetoothA2DP: Bool { get }
}

/// A clip the lens started (issue #41, phase 4): the token to stop it by, and whether it plays on the glasses.
struct LensSoundStart: Equatable {
    let clip: Int
    /// False when the audio route is not the glasses' A2DP speakers, so the clip plays on the phone.
    let onGlasses: Bool
}

/// The player as the lens adapter uses it: clips named by the pack's sound id, one at a time with the phone's.
@MainActor
protocol LensSoundOutput: AnyObject {
    /// Plays `sound`, replacing any clip playing. `onEnd` is called once when it ends for any reason (played out,
    /// stopped, replaced by another clip). Nil when it did not start: unknown to the packs, a failure, or a later
    /// tap or stop that came first.
    func play(_ sound: LensSound, onEnd: @escaping () -> Void) async -> LensSoundStart?
    /// Stops the clip `clip` names, if it is still the one playing.
    func stop(clip: Int)
    /// Cancels `sound` while it waits for the audio session, before it has a token to stop it by.
    func cancelStart(of sound: LensSound)
}

/// `SoundPlayer` over `AVAudioPlayer`, for the AAC clips in the packs.
@MainActor
final class AVSoundPlayer: NSObject, SoundPlayer {
    enum PlayError: LocalizedError {
        case didNotStart

        var errorDescription: String? { "The recording could not be played." }
    }

    var onFinish: (() -> Void)?
    private var player: AVAudioPlayer?

    var isPlaying: Bool { player?.isPlaying ?? false }

    func play(_ url: URL) throws {
        player?.stop()
        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = self
        self.player = player
        guard player.play() else {
            self.player = nil
            throw PlayError.didNotStart
        }
    }

    func stop() {
        player?.stop()
        player = nil
    }

    /// The delegate is called on whatever thread the player chooses; only the clip still current counts.
    fileprivate func ended(_ identity: ObjectIdentifier) {
        guard let player, ObjectIdentifier(player) == identity else { return }
        self.player = nil
        onFinish?()
    }
}

extension AVSoundPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let identity = ObjectIdentifier(player)
        Task { @MainActor in self.ended(identity) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        let identity = ObjectIdentifier(player)
        Task { @MainActor in self.ended(identity) }
    }
}

/// The shared session in `.playback` for the clip, and released with `.notifyOthersOnDeactivation` after it, so the
/// birder's own music or podcast comes back. Activation blocks (the runtime flags `setActive` on the main thread as
/// a hang risk), so both run on one serial queue, which also keeps a release from landing after the next clip's
/// activation.
@MainActor
final class SystemPlaybackAudioSession: PlaybackAudioSession {
    private nonisolated static let logger = Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "sounds")
    private let queue = DispatchQueue(label: "com.matthewcelia.mybirdjournal.playback-session", qos: .userInitiated)

    func activate() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playback, mode: .default)
                    try session.setActive(true)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    var routesToBluetoothA2DP: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .bluetoothA2DP }
    }

    func deactivate() {
        queue.async {
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                Self.logger.error("deactivate failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
