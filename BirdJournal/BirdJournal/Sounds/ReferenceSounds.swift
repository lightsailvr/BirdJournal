import Identification
import Observation
import OSLog
import Pack

/// The pack's reference clips as the phone plays them (issue #41): one at a time, a tap on the playing one stops it.
/// While a clip plays, and for a tail after it, `suppression` keeps the listening run from hearing it, whichever
/// microphone the run uses. A phone-microphone run already holds the audio session in `.playAndRecord`, which plays
/// too, so the clip leaves it alone; otherwise the clip takes the session in `.playback` and lets it go after.
@MainActor
@Observable
final class ReferenceSounds {
    /// The clip playing, nil when none is.
    private(set) var playing: PackSound.ID?

    /// How long past a clip's own length its end may go unreported before it is taken as over: a session another
    /// owner deactivates (a phone run stopping mid-clip) stops the player without a delegate call.
    static let endGrace: Duration = .seconds(1)

    @ObservationIgnored private let player: any SoundPlayer
    @ObservationIgnored private let session: any PlaybackAudioSession
    @ObservationIgnored private let suppression: AudioSuppression
    @ObservationIgnored private let phoneRunHoldsSession: () -> Bool
    /// Whether the clip took the session, so the release is the clip's to make.
    @ObservationIgnored private var holdsSession = false
    /// Bumped by every tap and stop, so a tap that waited for the session plays only if nothing came after it.
    @ObservationIgnored private var tapGeneration = 0
    /// The clip a tap is waiting on the session for; a second tap on it cancels it.
    @ObservationIgnored private var starting: PackSound.ID?
    @ObservationIgnored private var endWatch: Task<Void, Never>?
    private static let logger = Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "sounds")

    /// - Parameter phoneRunHoldsSession: whether a phone-microphone run holds the audio session now.
    init(player: any SoundPlayer, session: any PlaybackAudioSession, suppression: AudioSuppression, phoneRunHoldsSession: @escaping () -> Bool) {
        self.player = player
        self.session = session
        self.suppression = suppression
        self.phoneRunHoldsSession = phoneRunHoldsSession
        player.onFinish = { [weak self] in self?.finished() }
    }

    /// Plays `sound` from `url`, or stops it if it is the one playing or about to; another clip playing is stopped
    /// first.
    func toggle(_ sound: PackSound, at url: URL) async {
        if playing == sound.id || starting == sound.id {
            stop()
            return
        }
        tapGeneration += 1
        let generation = tapGeneration
        if playing != nil {
            player.stop()
            playing = nil
            endWatch?.cancel()
            suppression.end()
        }
        if !phoneRunHoldsSession() && !holdsSession {
            starting = sound.id
            do {
                try await session.activate()
                holdsSession = true
            } catch {
                Self.logger.error("session for playback failed: \(error.localizedDescription, privacy: .public)")
            }
            guard generation == tapGeneration else {
                // A later tap or a stop took over; it plays or releases, unless nothing is left to.
                if playing == nil && starting == nil { releaseSession() }
                return
            }
            starting = nil
        }
        suppression.begin()
        do {
            try player.play(url)
            playing = sound.id
            watchForEnd(of: sound)
        } catch {
            Self.logger.error("play failed: \(error.localizedDescription, privacy: .public)")
            suppression.end()
            releaseSession()
        }
    }

    /// Stops the clip playing, or the one waiting to start, if any.
    func stop() {
        tapGeneration += 1
        starting = nil
        guard playing != nil else { return }
        player.stop()
        ended()
    }

    private func finished() {
        guard playing != nil else { return }
        ended()
    }

    private func ended() {
        playing = nil
        endWatch?.cancel()
        endWatch = nil
        suppression.end()
        releaseSession()
    }

    /// Ends the clip if the player stopped without saying so, so listening is not left silenced.
    private func watchForEnd(of sound: PackSound) {
        endWatch?.cancel()
        endWatch = Task { [weak self] in
            try? await Task.sleep(for: sound.duration + Self.endGrace)
            guard !Task.isCancelled, let self, self.playing == sound.id, !self.player.isPlaying else { return }
            Self.logger.info("clip \(sound.id, privacy: .public) stopped unreported")
            self.ended()
        }
    }

    /// Lets the session go if the clip took it; a phone run that started meanwhile has made it its own.
    private func releaseSession() {
        guard holdsSession else { return }
        holdsSession = false
        if !phoneRunHoldsSession() { session.deactivate() }
    }
}
