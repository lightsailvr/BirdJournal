import Foundation
import Identification
import LensSession
import Pack
import Testing
@testable import BirdJournal

// Issue #41, phase 3: the profile's Song and Call buttons. The player and the audio session are doubles at their
// seams (`SoundPlayer`, `PlaybackAudioSession`); the playback rules under test are real.
@MainActor
@Suite("Reference sounds")
struct ReferenceSoundsTests {
    let player = MockSoundPlayer()
    let session = SpyPlaybackSession()
    let suppression = AudioSuppression(tail: .zero)

    func makeSounds(recording: @escaping () -> Bool = { false }) -> ReferenceSounds {
        ReferenceSounds(player: player, session: session, suppression: suppression, phoneRunHoldsSession: recording) { id in
            [Self.song, Self.call].first { $0.id == id }.map { ($0, $0.id == Self.song.id ? Self.songURL : Self.callURL) }
        }
    }

    @Test("a song plays to its end: the session is taken for the clip, listening hears nothing while it plays, and both are let go after")
    func playsToTheEnd() async {
        let sounds = makeSounds()

        await sounds.toggle(Self.song, at: Self.songURL)
        #expect(sounds.playing == Self.song.id)
        #expect(player.played == [Self.songURL])
        #expect(session.calls == [.activate])
        #expect(suppression.isSuppressing)

        player.finish()
        #expect(sounds.playing == nil)
        #expect(session.calls == [.activate, .deactivate])
        #expect(!suppression.isSuppressing)
    }

    @Test("a tap on the playing clip stops it")
    func tapStops() async {
        let sounds = makeSounds()

        await sounds.toggle(Self.song, at: Self.songURL)
        await sounds.toggle(Self.song, at: Self.songURL)
        #expect(sounds.playing == nil)
        #expect(player.stops == 1)
        #expect(session.calls == [.activate, .deactivate])
        #expect(!suppression.isSuppressing)
    }

    @Test("the call while the song plays: the song stops, the call plays, and the session and suppression hold throughout")
    func switchesClips() async {
        let sounds = makeSounds()

        await sounds.toggle(Self.song, at: Self.songURL)
        await sounds.toggle(Self.call, at: Self.callURL)
        #expect(sounds.playing == Self.call.id)
        #expect(player.played == [Self.songURL, Self.callURL])
        #expect(session.calls == [.activate])
        #expect(suppression.isSuppressing)

        sounds.stop()
        #expect(sounds.playing == nil)
        #expect(session.calls == [.activate, .deactivate])
        #expect(!suppression.isSuppressing)
    }

    @Test("while the phone microphone listens, the clip plays in its session, which is left alone, and is still not heard")
    func playsBesideThePhoneMicrophone() async {
        let sounds = makeSounds(recording: { true })

        await sounds.toggle(Self.song, at: Self.songURL)
        #expect(sounds.playing == Self.song.id)
        #expect(session.calls.isEmpty)
        #expect(suppression.isSuppressing)

        player.finish()
        #expect(session.calls.isEmpty)
        #expect(!suppression.isSuppressing)
    }

    @Test("a phone run that starts during the clip keeps its session when the clip ends")
    func runStartedDuringTheClip() async {
        var recording = false
        let sounds = makeSounds(recording: { recording })

        await sounds.toggle(Self.song, at: Self.songURL)
        recording = true
        player.finish()
        #expect(session.calls == [.activate], "deactivating would stop the microphone")
    }

    @Test("a clip that cannot play leaves nothing playing, held or taken")
    func failedPlay() async {
        player.failNext = true
        let sounds = makeSounds()

        await sounds.toggle(Self.song, at: Self.songURL)
        #expect(sounds.playing == nil)
        #expect(session.calls == [.activate, .deactivate])
        #expect(!suppression.isSuppressing)
    }

    @Test("leaving the profile while the session is still being taken: the clip never starts and the session is let go")
    func stopWhileStarting() async {
        session.holdActivation = true
        let sounds = makeSounds()

        let tap = Task { await sounds.toggle(Self.song, at: Self.songURL) }
        await session.activationRequested()
        sounds.stop()
        session.releaseActivation()
        await tap.value

        #expect(sounds.playing == nil)
        #expect(player.played.isEmpty)
        #expect(session.calls == [.activate, .deactivate])
        #expect(!suppression.isSuppressing)
    }

    @Test("a second tap on the row while the session is still being taken cancels the clip")
    func secondTapWhileStarting() async {
        session.holdActivation = true
        let sounds = makeSounds()

        let tap = Task { await sounds.toggle(Self.song, at: Self.songURL) }
        await session.activationRequested()
        await sounds.toggle(Self.song, at: Self.songURL)
        session.releaseActivation()
        await tap.value

        #expect(sounds.playing == nil)
        #expect(player.played.isEmpty)
        #expect(session.calls == [.activate, .deactivate])
    }

    @Test("a clip whose player stops unreported (its session deactivated by a phone run ending) is ended after its length, so listening is not left silenced")
    func unreportedStop() async throws {
        let sounds = makeSounds()
        let short = PackSound(
            id: "xc-3", speciesID: "s1", rank: 0, kind: .song, file: "sounds/xc-3.m4a", duration: .milliseconds(10),
            recordist: "C", license: "CC0", creditLine: "C", shortCredit: "Sound: C", sourceURL: URL(string: "https://xeno-canto.org/3")!, quality: nil
        )

        await sounds.toggle(short, at: Self.songURL)
        player.stopUnreported()
        #expect(suppression.isSuppressing)

        let deadline = ContinuousClock.now + .seconds(5)
        while sounds.playing != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(sounds.playing == nil)
        #expect(!suppression.isSuppressing)
        #expect(session.calls == [.activate, .deactivate])
    }

    // MARK: - The lens (phase 4)

    @Test("the lens plays a clip by the pack's id, is told the route, and hears of its end once")
    func lensPlaysToTheEnd() async throws {
        let sounds = makeSounds()
        session.onBluetoothA2DP = true
        var ends = 0

        let start = try #require(await sounds.play(LensSound(id: "xc-2", kind: .call)) { ends += 1 })
        #expect(start.onGlasses)
        #expect(sounds.playing == Self.call.id)
        #expect(player.played == [Self.callURL])
        #expect(session.calls == [.activate])
        #expect(suppression.isSuppressing)

        player.finish()
        #expect(ends == 1)
        #expect(sounds.playing == nil)
        #expect(session.calls == [.activate, .deactivate])
        #expect(!suppression.isSuppressing)
    }

    @Test("off the glasses' A2DP route the lens is told the clip plays on the phone")
    func lensOnPhone() async throws {
        let sounds = makeSounds()
        session.onBluetoothA2DP = false
        let start = try #require(await sounds.play(LensSound(id: "xc-1", kind: .song)) {})
        #expect(!start.onGlasses)
    }

    @Test("the lens stops only its own clip: a stale token leaves the clip playing now alone")
    func lensStopsItsOwnClip() async throws {
        let sounds = makeSounds()
        var songEnds = 0
        let song = try #require(await sounds.play(LensSound(id: "xc-1", kind: .song)) { songEnds += 1 })
        // The phone's profile plays the call over it: the lens hears its clip ended.
        await sounds.toggle(Self.call, at: Self.callURL)
        #expect(songEnds == 1)
        #expect(sounds.playing == Self.call.id)

        sounds.stop(clip: song.clip)
        #expect(sounds.playing == Self.call.id, "the phone's clip plays on")

        var callEnds = 0
        let call = try #require(await sounds.play(LensSound(id: "xc-2", kind: .call)) { callEnds += 1 })
        #expect(call.clip != song.clip)
        sounds.stop(clip: call.clip)
        #expect(callEnds == 1)
        #expect(sounds.playing == nil)
        #expect(session.calls == [.activate, .deactivate])
    }

    @Test("a lens clip cancelled while the session is still being taken never starts, and the session is let go")
    func lensCancelWhileStarting() async {
        session.holdActivation = true
        let sounds = makeSounds()
        let lensSong = LensSound(id: "xc-1", kind: .song)

        let tap = Task { await sounds.play(lensSong) {} }
        await session.activationRequested()
        sounds.cancelStart(of: lensSong)
        session.releaseActivation()
        let start = await tap.value

        #expect(start == nil)
        #expect(player.played.isEmpty)
        #expect(session.calls == [.activate, .deactivate])
        #expect(!suppression.isSuppressing)
    }

    @Test("a clip the packs do not hold is not played")
    func lensUnknownClip() async {
        let sounds = makeSounds()
        let start = await sounds.play(LensSound(id: "xc-404", kind: .song)) {}
        #expect(start == nil)
        #expect(player.played.isEmpty && session.calls.isEmpty)
    }

    static let song = PackSound(
        id: "xc-1", speciesID: "s1", rank: 0, kind: .song, file: "sounds/xc-1.m4a", duration: .milliseconds(8_000),
        recordist: "A. Recordist", license: "CC BY-SA 4.0", creditLine: "A. Recordist, XC1, https://xeno-canto.org/1 (CC BY-SA 4.0)",
        shortCredit: "Sound: A. Recordist, XC1", sourceURL: URL(string: "https://xeno-canto.org/1")!, quality: "A"
    )
    static let call = PackSound(
        id: "xc-2", speciesID: "s1", rank: 1, kind: .call, file: "sounds/xc-2.m4a", duration: .milliseconds(8_000),
        recordist: "B. Recordist", license: "CC BY-NC-SA 4.0", creditLine: "B. Recordist, XC2, https://xeno-canto.org/2 (CC BY-NC-SA 4.0)",
        shortCredit: "Sound: B. Recordist, XC2", sourceURL: URL(string: "https://xeno-canto.org/2")!, quality: "B"
    )
    static let songURL = URL(fileURLWithPath: "/packs/la/sounds/xc-1.m4a")
    static let callURL = URL(fileURLWithPath: "/packs/la/sounds/xc-2.m4a")
}

// MARK: - Doubles

@MainActor
final class MockSoundPlayer: SoundPlayer {
    var onFinish: (() -> Void)?
    private(set) var isPlaying = false
    private(set) var played: [URL] = []
    private(set) var stops = 0
    var failNext = false

    struct Failed: Error {}

    func play(_ url: URL) throws {
        if failNext {
            failNext = false
            throw Failed()
        }
        played.append(url)
        isPlaying = true
    }

    func stop() {
        if isPlaying { stops += 1 }
        isPlaying = false
    }

    /// The player stops without a delegate call, as when another owner deactivates the session.
    func stopUnreported() {
        isPlaying = false
    }

    /// The clip plays to its end.
    func finish() {
        isPlaying = false
        onFinish?()
    }
}

@MainActor
final class SpyPlaybackSession: PlaybackAudioSession {
    enum Call: Equatable {
        case activate
        case deactivate
    }

    private(set) var calls: [Call] = []
    var onBluetoothA2DP = false
    /// Keeps `activate()` waiting until `releaseActivation()`.
    var holdActivation = false
    private var held: CheckedContinuation<Void, Never>?
    private var requested: CheckedContinuation<Void, Never>?

    func activate() async throws {
        calls.append(.activate)
        guard holdActivation else { return }
        await withCheckedContinuation { continuation in
            held = continuation
            requested?.resume()
            requested = nil
        }
    }

    /// Returns once an activation is waiting.
    func activationRequested() async {
        guard held == nil else { return }
        await withCheckedContinuation { requested = $0 }
    }

    func releaseActivation() {
        held?.resume()
        held = nil
    }
    func deactivate() { calls.append(.deactivate) }
    var routesToBluetoothA2DP: Bool { onBluetoothA2DP }
}
