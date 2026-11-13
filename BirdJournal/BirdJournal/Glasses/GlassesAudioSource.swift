import CoreMedia
import Foundation
import Identification
import ImageIO
import MWDATCamera
import MWDATCore
import Synchronization
import UIKit

/// Ambient audio from the glasses, which only arrives in-band on a camera stream (DECISIONS.md, "Toolkit facts").
/// Video runs at the lowest resolution and frame rate to save battery; frames are not used for identification, but
/// the most recent one is kept for the add's viewfinder and as the stand-in for a sighting's photo (issue #9).
///
/// A photo is a still from the camera's photo mode (`Camera.photo`), the toolkit's counterpart of the glasses' own
/// shutter, taken the way Meta's BirdSpotter sample takes its own as far as the glasses allow it (2026-11-12): the
/// mode is started on the same camera once the stream has woken it, and for a still the stream is stopped on that
/// camera. Stills asked for while others are crossing join a queue (`stills`); when it is empty the camera leaves
/// the session and listening comes back on a new one, since the stream would not start again on the old. A still
/// on a fresh camera with no stream never started here (#46: the mode cannot wake the camera), and a photo taken in
/// the stream took 9 to 12 s to cross beside the audio.
///
/// A pause the toolkit reports (`.paused` on the session and stream) is left to it to resume. A session the glasses
/// end (a doff ends it and drops the link, DECISIONS.md phase A) is survived instead (issue #10): the run calls
/// `suspend()`, which drops the camera but keeps the chunk stream open so the engine waits rather than ends, and
/// `resume(on:)` with the next session, which continues the same chunk stream.
///
/// The glasses do not play a reference clip on their speakers while the camera streams (seen on hardware,
/// 2026-10-10: iOS routed the clip to their A2DP output and nothing played), so a clip holds the stream
/// (`holdForPlayback()`): the camera comes off the session, which stays up with the lens on it, and goes back on
/// `restartDelay` after the last clip ends, so a song then a call does not restart it in between. The paused span is
/// filled with silence when the audio returns, so the engine's windows do not splice the audio either side together
/// and its clock stays on the run's. `camera.stop()` finishes asynchronously and a stopped camera cannot be reused, so
/// the restart waits for the old camera to reach `.stopped`, adds a fresh one, and waits for its stream to reach
/// `.streaming`; a start that does not get there is stopped and tried again with another fresh camera (the toolkit's
/// capabilities fail to start intermittently, and the next attempt then succeeds), up to `restartAttempts` times, and
/// after that again every `retryDelay` while the run lasts. A stream that stopped with nothing holding it, or went
/// quiet, is put back when the lens asks for it (`ensureStreaming(_:)`: landing on the species list, opening the
/// viewfinder), since a field test lost listening after several adds and clips (#46).
///
/// Explicitly main-actor: conforming to the `Sendable` `AudioSource` protocol would otherwise make the class
/// nonisolated under the target's default main-actor isolation. Single use: create one per listening run.
@MainActor
final class GlassesAudioSource: FrameKeepingAudioSource, PlaybackStreamHold, DictationStreamHold {
    /// Session and stream lifecycle, for the spike log.
    enum Event: Sendable {
        case sessionState(DeviceSessionState)
        case sessionError(DeviceSessionError)
        case streamState(StreamState)
        case streamError(StreamError)
    }

    enum StartError: LocalizedError {
        case cameraUnavailable
        case notStarted

        var errorDescription: String? {
            switch self {
            case .cameraUnavailable: "The glasses camera stream could not be added to the session."
            case .notStarted: "The glasses audio source is not running."
            }
        }
    }

    let sampleRate: AudioSampleRate
    let events: AsyncStream<Event>

    private(set) var sessionState: DeviceSessionState = .idle
    private(set) var streamState: StreamState = .stopped

    private let wearables: any WearablesInterface
    private let lease: DeviceSessionLease
    private let onLevel: (@Sendable (AudioLevel) -> Void)?
    private let eventContinuation: AsyncStream<Event>.Continuation
    private var session: DeviceSession?
    private var camera: Camera?
    private var chunkContinuation: AsyncStream<AudioChunk>.Continuation?
    /// The session's listeners.
    private let tokens = ListenerTokenBag()
    /// The current camera stream's listeners, released on their own when a clip holds the stream. A fresh bag for
    /// each camera, so releasing an old camera's listeners can never take a newer camera's with them.
    private var cameraTokens = ListenerTokenBag()
    /// Written straight from the video frame callback; read on confirm.
    private nonisolated let latestVideoFrame = Mutex<VideoFrame?>(nil)
    /// When a clip took the camera off, until the first audio after it comes back fills the span with silence.
    private nonisolated let heldSince = Mutex<ContinuousClock.Instant?>(nil)
    /// When the current camera last delivered audio, or was added or began streaming if it has not yet: how
    /// `ensureStreaming(_:)` tells a stream that went quiet.
    private nonisolated let lastAudio = Mutex<ContinuousClock.Instant?>(nil)
    /// What has the listening camera off the session: a clip playing, a full-resolution photo being taken, a
    /// dictation, or the capture camera.
    private enum Hold { case playback, photo, dictation, capture }
    private var holds: Set<Hold> = []
    /// The in-stream capture waiting for its photo, and when the last one was asked for: a photo that arrives after
    /// its wait is logged with how late it was.
    private var photoWait: (id: Int, continuation: CheckedContinuation<Data?, Never>)?
    private var photoWaits = 0
    private var photoRequestedAt: ContinuousClock.Instant?
    /// The camera's photo mode (`Camera.photo`), which takes a still without a stream: started once the stream has
    /// woken the camera, and kept started for as long as the camera is on the session.
    /// Its state as last published, written straight from the toolkit's callback: read through a hop to the main
    /// actor each, the states could arrive out of order, and a `started` landing after the `stopped` that followed
    /// it leaves a mode that is down looking up.
    private nonisolated let publishedPhotoState = Mutex<PhotoState>(.stopped)
    private var photoState: PhotoState { publishedPhotoState.withLock { $0 } }
    /// The state the log last named.
    private var loggedPhotoState: PhotoState = .stopped
    /// The stills asked for and not yet in, oldest first. Each is asked of the glasses as soon as its tap comes, so
    /// its shutter is at the tap and not after the photos ahead of it have crossed; the glasses send them one after
    /// another, and their answers carry no request, so an arrival is the oldest one's (the maintainer's flow,
    /// 2026-11-12: tap for another photo while one is crossing).
    private var stills: [StillRequest] = []
    private var stillCount = 0
    /// One pass through the queue at a time, and the camera on its way off once the queue is empty.
    private var isAskingStills = false
    private var isEndingStills = false
    /// When bytes of a still last crossed, or one was asked for: the oldest is given up on when the link has been
    /// quiet too long, not when the photo is merely large.
    private var stillLastActivity: ContinuousClock.Instant?
    private var stillWatch: Task<Void, Never>?
    /// When bytes of the in-stream photo being waited for last crossed, or it was asked for.
    private var photoLastActivity: ContinuousClock.Instant?
    /// The sizes of transfers given up on part way (a stall, or the wearer's cancel). The glasses go on with such a
    /// transfer when the next still is asked for (2026-11-12: the photo that came for the second tap was the first
    /// tap's, by its size), so one that resumes is told apart, by `earlierTotal` while it crosses, and kept as its
    /// own photo.
    private var abandonedTotals: Set<UInt64> = []
    private var earlierTotal: UInt64?
    /// Given a photo that belongs to an earlier tap, whose wait had ended: the run keeps it to name.
    var onEarlierPhoto: ((Data) -> Void)?
    /// Plays the capture's sound through the glasses, the chime before listening comes back; nil plays none. It is
    /// played with the stream off: the glasses play nothing while the camera streams (2026-10-10).
    var cues: (any CaptureCuePlaying)?
    /// Whether the sound for listening coming back is owed: a photo stopped it.
    private var resumeCueOwed = false
    /// When the glasses say they took the last still that arrived.
    private var stillTimestamp: Date?
    /// Whether a still can be taken now.
    var isPhotoModeStarted: Bool { photoState == .started }
    private var photoStartRequested = false
    private var photoTokens = ListenerTokenBag()
    /// Whether the stream is stopped on a camera that is still on the session, for a still or for a capture.
    private var streamSetAside = false
    /// Whether a photo is being taken, by either path.
    private var isTakingPhoto: Bool { !stills.isEmpty || photoWait != nil }
    /// Puts the camera back once the last clip has been over for `restartDelay`.
    private var restartTask: Task<Void, Never>?
    /// Finishes once the camera a clip took off has stopped (or `stopTimeout` passed); the restart waits for it.
    private var cameraStopped: Task<Void, Never>?

    /// How long after a clip ends the stream waits before it restarts, for the next clip.
    static let restartDelay: Duration = .seconds(1)
    /// The longest silence a hold fills in; a longer one is left as a gap.
    nonisolated static let longestFill: Duration = .seconds(120)
    /// How many fresh cameras a restart after a clip tries before it gives up.
    static let restartAttempts = 3
    /// How long a camera taken off may take to stop.
    static let stopTimeout: Duration = .seconds(3)
    /// How long a restarted stream may take to reach `.streaming`; one that stops first has failed already. The
    /// glasses took 5.8 and 6.3 s over good starts on 2026-11-07 and 11-12, and a start they reject says so within
    /// two or three, so the wait is only ever sat out by a start that hangs.
    static let startTimeout: Duration = .seconds(12)
    /// How long the session may take to come back to `.started` before a restart.
    static let sessionTimeout: Duration = .seconds(10)
    /// How long after `restartAttempts` failed starts the restart tries again.
    static let retryDelay: Duration = .seconds(10)
    /// How long a running camera may go without audio before `ensureStreaming(_:)` takes it for stalled; audio
    /// arrives within a second of `.streaming` and then continuously.
    static let audioStall: Duration = .seconds(5)
    /// How long a stream may be starting (`.waitingForDevice`, `.starting`) before `ensureStreaming(_:)` takes it for
    /// stalled. A start is not a stall: on 2026-11-12 the viewfinder was opened 7 s into a run, the stream that was
    /// about to come up was taken for quiet and replaced, and the restarts that followed kept the wearer waiting 34 s.
    static let startAllowance: Duration = .seconds(20)
    /// How long a photo taken in the stream may take before the sighting goes without it. On 2026-11-12 two of
    /// 270 KB came 9.1 and 11.8 s after they were asked for, beside the stream's audio. Only used when the photo mode
    /// is not up.
    static let photoTimeout: Duration = .seconds(15)
    /// How long a still's transfer may be quiet before it is given up on (the toolkit's own limit). On 2026-11-12 a 12 MP still of 1.3 to 1.9 MB crossed at 30 to 40 KB a second: 11 and 29 s for
    /// two, and a third was still crossing when a fixed 45 s gave up on it.
    static let stillQuiet: Duration = .seconds(30)
    /// How long the photo mode may take to start once the stream is up, before a photo goes to the stream instead.
    static let photoStartTimeout: Duration = .seconds(5)
    /// How long a stream set aside for a still gets to let go of the camera before the still is asked for anyway.
    static let setAsideTimeout: Duration = .seconds(2)

    /// - Parameter onLevel: told each chunk's level as it arrives (on the toolkit's thread), for the phone's waveform.
    init(wearables: any WearablesInterface = Wearables.shared, lease: DeviceSessionLease = .own, sampleRate: AudioSampleRate = .rate48000, onLevel: (@Sendable (AudioLevel) -> Void)? = nil) {
        self.wearables = wearables
        self.lease = lease
        self.sampleRate = sampleRate
        self.onLevel = onLevel
        (events, eventContinuation) = AsyncStream.makeStream(of: Event.self)
    }

    /// The most recent video frame the stream delivered, nil until the first one arrives and after `stop()`.
    var latestFrame: CameraFrame? { latestVideoFrame.withLock { $0 }.map(CameraFrame.init) }

    /// The stream configuration: raw video at 360×640 and 2 fps (the toolkit's minimum), PCM mono audio. The glasses
    /// rejected 504×896 at 7 fps with PCM audio (#46).
    var configuration: StreamConfiguration {
        StreamConfiguration(
            videoCodec: .raw,
            audioCodec: .pcm(sampleRate: sampleRate, numberOfChannels: 1),
            resolution: .low,
            frameRate: 2
        )
    }

    func start() async throws -> AsyncStream<AudioChunk> {
        do {
            return try await startStreaming()
        } catch {
            // Whatever was set up before the failure (session, camera, listeners) is torn down here.
            await stop()
            throw error
        }
    }

    private func startStreaming() async throws -> AsyncStream<AudioChunk> {
        try await wearables.ensurePermission(.camera)
        try await wearables.ensurePermission(.microphone)

        let session = try await lease.session(wearables: wearables, listen: listen(to:))
        let (chunks, continuation) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .bufferingNewest(1_024))
        chunkContinuation = continuation
        try attachCamera(to: session, feeding: continuation)
        return chunks
    }

    private func listen(to session: DeviceSession) {
        session.statePublisher.listen { [weak self] state in
            Task { @MainActor in self?.handle(.sessionState(state)) }
        }.store(in: tokens)
        session.errorPublisher.listen { [weak self] error in
            Task { @MainActor in self?.handle(.sessionError(error)) }
        }.store(in: tokens)
    }

    /// Adds the camera to `session` with its stream feeding `continuation`, and starts the stream unless `start` is
    /// false (the restart starts it under a wait for `.streaming`).
    @discardableResult
    private func attachCamera(to session: DeviceSession, feeding continuation: AsyncStream<AudioChunk>.Continuation, start: Bool = true) throws -> Camera {
        self.session = session
        guard let camera = try session.addCamera(config: configuration) else {
            throw StartError.cameraUnavailable
        }
        self.camera = camera
        listenToStream(of: camera, feeding: continuation)
        listenToPhotoMode(of: camera)

        if start { camera.stream.start() }
        return camera
    }

    /// The stream's listeners, in a bag of their own: taken afresh each time the stream is started on a camera,
    /// since whether a listener outlives a stop and a start of the stream is not documented.
    private func listenToStream(of camera: Camera, feeding continuation: AsyncStream<AudioChunk>.Continuation) {
        let cameraTokens = ListenerTokenBag()
        self.cameraTokens = cameraTokens
        lastAudio.withLock { $0 = .now }

        let onLevel = onLevel
        let firstAudio = Once()
        let firstFrame = Once()
        camera.stream.audioFramePublisher.listen { [weak self] frame in
            if firstAudio.claim() { Task { @MainActor in GlassesLog.shared.note("first audio on the stream") } }
            self?.lastAudio.withLock { $0 = .now }
            let chunk = AudioChunk(buffer: frame.pcmBuffer, presentationTime: frame.presentationTimeStamp.seconds)
            guard let chunk else { return }
            if let since = self?.heldSince.withLock({ held in defer { held = nil }; return held }) {
                let span = ContinuousClock.now - since
                if span <= Self.longestFill, let silence = AudioChunk.silence(lasting: span, at: chunk.sampleRate, before: chunk) {
                    continuation.yield(silence)
                }
            }
            onLevel?(AudioLevelMeter.level(of: chunk))
            continuation.yield(chunk)
        }.store(in: cameraTokens)
        camera.stream.videoFramePublisher.listen { [weak self] frame in
            if firstFrame.claim() { Task { @MainActor in GlassesLog.shared.note("first video frame on the stream") } }
            self?.latestVideoFrame.withLock { $0 = frame }
        }.store(in: cameraTokens)
        camera.stream.photoDataPublisher.listen { [weak self] photo in
            let data = photo.data
            Task { @MainActor in self?.photoArrived(data) }
        }.store(in: cameraTokens)
        camera.stream.statePublisher.listen { [weak self] state in
            Task { @MainActor in self?.handle(.streamState(state)) }
        }.store(in: cameraTokens)
        camera.stream.errorPublisher.listen { [weak self] error in
            Task { @MainActor in self?.handle(.streamError(error)) }
        }.store(in: cameraTokens)
    }

    /// The photo mode's listeners, for the life of the camera: its state, its stills and its errors. They are in
    /// place before it is started, because nothing it publishes is replayed.
    private func listenToPhotoMode(of camera: Camera) {
        let tokens = ListenerTokenBag()
        photoTokens = tokens
        publishedPhotoState.withLock { $0 = .stopped }
        loggedPhotoState = .stopped
        photoStartRequested = false
        let photo = camera.photo
        photo.statePublisher.listen { [weak self] state in
            self?.publishedPhotoState.withLock { $0 = state }
            Task { @MainActor in self?.photoModeChanged(on: camera) }
        }.store(in: tokens)
        photo.photoDataPublisher.listen { [weak self] captured in
            let data = captured.imageData
            let timestamp = captured.timestamp
            Task { @MainActor in
                self?.stillTimestamp = timestamp
                self?.stillArrived(data)
            }
        }.store(in: tokens)
        photo.transferProgressPublisher.listen { [weak self] progress in
            let received = progress.bytesReceived, total = progress.totalBytes
            Task { @MainActor in self?.stillProgressed(received: received, of: total) }
        }.store(in: tokens)
        photo.errorPublisher.listen { [weak self] error in
            let text = error.description
            Task { @MainActor in self?.photoModeFailed(text) }
        }.store(in: tokens)
    }

    /// The stream is up, so the camera is awake: the photo mode can start. Started on a camera nothing has woken it
    /// sits at `starting` for ever, which is what the standalone still did here in October (#46); Meta's BirdSpotter
    /// sample starts it at this moment and leaves it started.
    private func startPhotoModeIfNeeded() {
        guard let camera, !photoStartRequested, photoState == .stopped else { return }
        photoStartRequested = true
        camera.photo.start()
    }

    private func photoModeChanged(on camera: Camera) {
        let state = photoState
        guard self.camera === camera, state != loggedPhotoState else { return }
        loggedPhotoState = state
        GlassesLog.shared.note("photo mode: \(state)")
        // One that went down is asked for again the next time the stream comes up.
        if state == .stopped { photoStartRequested = false }
    }

    /// Bytes of a still have crossed: the oldest one's. Its first bytes are the moment the glasses have the photo, which
    /// the lens says (the photo mode makes no shutter sound), and each tenth after is told too.
    private func stillProgressed(received: UInt64, of total: UInt64) {
        stillLastActivity = .now
        if abandonedTotals.contains(total) {
            if earlierTotal != total {
                earlierTotal = total
                GlassesLog.shared.note("stills: an earlier photo's transfer has resumed (\(received) of \(total))")
            }
            return
        }
        earlierTotal = nil
        guard let index = stills.firstIndex(where: { $0.asked != nil }), let asked = stills[index].asked else { return }
        let id = stills[index].id
        stills[index].total = total
        if stills[index].firstBytes == nil {
            stills[index].firstBytes = .now
            GlassesLog.shared.note("still \(id): first bytes \(Self.seconds(since: asked.clock)) after it was asked for (\(received) of \(total))")
        }
        let fraction = total > 0 ? min(Double(received) / Double(total), 1) : 0
        let tenth = Int(fraction * 10)
        guard tenth > stills[index].tenth else { return }
        stills[index].tenth = tenth
        if tenth > 0 { GlassesLog.shared.note("still \(id): \(tenth * 10)% at \(Self.seconds(since: asked.clock)) (\(received) bytes)") }
        stills[index].progress(fraction)
    }

    /// A still arrived: the oldest one asked for. One whose transfer was given up on earlier belongs to that earlier
    /// tap: it is handed over as its own photo, and the wait for the ones in the queue goes on.
    private func stillArrived(_ data: Data) {
        stillLastActivity = .now
        if let total = earlierTotal {
            abandonedTotals.remove(total)
            earlierTotal = nil
            GlassesLog.shared.note("stills: the earlier photo arrived (\(data.count) bytes), kept")
            keepEarlier(data)
            return
        }
        guard let request = stills.first(where: { $0.asked != nil }), let asked = request.asked else {
            GlassesLog.shared.error("stills: a photo arrived that none was waiting for (\(data.count) bytes), kept")
            keepEarlier(data)
            return
        }
        // The glasses' own time for the photo against the phone's for the request: how long after it the shutter
        // was, as far as the two clocks agree (1.5 s, the once it was measured).
        let shutter = stillTimestamp.map { String(format: "%.1f s", $0.timeIntervalSince(asked.date)) } ?? "?"
        let crossing = request.firstBytes.map { Self.seconds(ContinuousClock.now - $0) } ?? "?"
        GlassesLog.shared.note("still \(request.id): taken in \(Self.seconds(since: asked.clock)) (\(data.count) bytes, \(Self.pixelSize(of: data)), asked for \(request.size.summary); the glasses' time for it is \(shutter) after it was asked for, the crossing took \(crossing); \(Self.seconds(since: request.wanted)) from the tap)")
        finishStill(request.id, with: data)
    }

    private func keepEarlier(_ data: Data) {
        Task { [weak self] in
            let jpeg = await Task.detached(priority: .userInitiated) { Self.jpeg(data) }.value
            guard let jpeg else { return }
            self?.onEarlierPhoto?(jpeg)
        }
    }

    /// The photo mode reported an error, without saying which still it is about: one asked for in the last two
    /// seconds if there is one (the glasses refusing it: "busy", "not ready"), else the one crossing. It is asked for
    /// once more, when it is first in line, with the mode started afresh; a second error ends it.
    private func photoModeFailed(_ description: String) {
        GlassesLog.shared.error("photo mode error: \(description)")
        let now = ContinuousClock.now
        let asked = stills.filter { $0.asked != nil }
        guard let victim = asked.last(where: { request in request.asked.map { now - $0.clock < .seconds(2) } ?? false }) ?? asked.first,
              let index = stills.firstIndex(where: { $0.id == victim.id }) else { return }
        guard stills[index].attempts == 0 else {
            GlassesLog.shared.error("still \(victim.id): not taken, the glasses refused it twice")
            finishStill(victim.id, with: nil)
            return
        }
        stills[index].attempts = 1
        stills[index].asked = nil
        stills[index].firstBytes = nil
        stills[index].tenth = -1
        stills[index].total = nil
        GlassesLog.shared.note("still \(victim.id): refused, asked for again when it is first in line")
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            await self?.askForStills()
        }
    }

    func stop() async {
        restartTask?.cancel()
        restartTask = nil
        cameraStopped = nil
        holds.removeAll()
        await releaseCamera()
        chunkContinuation?.finish()
        chunkContinuation = nil
        // `events` stays open: a session error delivered just after a failed start must still reach the reader,
        // which cancels its own iteration when done.
    }

    /// The session ended under the stream (doff, link loss): the camera, its listeners and the stale frame go; the
    /// chunk stream stays open for `resume(on:)`, which puts the camera back itself.
    func suspend() async {
        restartTask?.cancel()
        restartTask = nil
        // A capture does not outlive its session: the lens asks again if it still needs the camera on the new one.
        holds.remove(.capture)
        await releaseCamera()
    }

    /// Continues the chunk stream on `session`, the one the run started once the glasses came back. Fails if the
    /// source was never started or has been stopped; a failure to attach leaves nothing on the session.
    func resume(on session: DeviceSession) async throws {
        guard let continuation = chunkContinuation else { throw StartError.notStarted }
        listen(to: session)
        do {
            try attachCamera(to: session, feeding: continuation)
        } catch {
            await releaseCamera()
            throw error
        }
    }

    /// Listeners go first so no frame lands after the chunk stream finishes or the camera is gone. A gap from a
    /// clip's hold is not filled across a lost session.
    private func releaseCamera() async {
        await tokens.cancelAll()
        await releaseListeners()
        await releasePhotoMode()
        camera?.stop()
        if lease.isOwned { session?.stop() }
        camera = nil
        session = nil
        latestVideoFrame.withLock { $0 = nil }
        heldSince.withLock { $0 = nil }
        lastAudio.withLock { $0 = nil }
        streamState = .stopped
    }

    // MARK: - Photos

    /// A photo from the camera, taken now, as a JPEG; nil when none came.
    ///
    /// A still from the photo mode, as the glasses' own shutter takes one. Before the mode is up (the first seconds of
    /// a run, a camera coming back after the last photos or a clip) the photo waits for it; if it does not come up
    /// beside a running stream, the photo is taken in the stream instead, which is slower beside the audio and no
    /// larger than 1080 × 1440.
    func capturePhoto() async -> Data? {
        await capturePhoto(progress: { _ in })
    }

    /// As `capturePhoto()`; `progress` is told how much of the photo has crossed to the phone, from the moment the
    /// glasses have it (some small fraction) to 1. Photos asked for while others are crossing join the queue: each
    /// is taken at once, and they arrive in the order they were taken.
    func capturePhoto(progress: @escaping @MainActor @Sendable (Double) -> Void) async -> Data? {
        guard chunkContinuation != nil else { return nil }
        stillCount += 1
        let id = stillCount
        let size = GlassesPhotoSize.current()
        let data: Data? = await withCheckedContinuation { continuation in
            stills.append(StillRequest(id: id, size: size, progress: progress, continuation: continuation, wanted: .now))
            Task { [weak self] in await self?.askForStills() }
        }
        guard let data else { return nil }
        return await Task.detached(priority: .userInitiated) { Self.jpeg(data) }.value
    }

    /// Gives up every photo not yet in, at the wearer's word, and lets listening come back. A transfer under way is
    /// remembered: if the glasses go on with it at a later photo, it is kept then.
    func cancelPhotos() async {
        guard !stills.isEmpty else { return }
        GlassesLog.shared.note("stills: \(stills.count) given up at the wearer's word")
        failStills()
        await endStills()
    }

    /// Ends every still in the queue without its photo.
    private func failStills() {
        let waiting = stills
        stills = []
        for request in waiting {
            if let total = request.total, request.firstBytes != nil { abandonedTotals.insert(total) }
            request.continuation.resume(returning: nil)
        }
    }

    /// Asks the glasses for every still in the queue that has not been asked for, in order: the stream is stopped on
    /// its camera for the first (the two cannot both have it), as Meta's BirdSpotter sample does, and stays stopped
    /// until the queue is empty. One the glasses refused waits until it is first in line.
    private func askForStills() async {
        guard !isAskingStills else { return }
        isAskingStills = true
        defer { isAskingStills = false }
        while let request = stills.first(where: { $0.asked == nil && ($0.attempts == 0 || $0.id == stills.first?.id) }) {
            let id = request.id
            await waitForPhotoMode()
            guard stills.contains(where: { $0.id == id }) else { continue }
            guard let camera else {
                GlassesLog.shared.error("still \(id): not taken, no camera is on the session")
                finishStill(id, with: nil)
                continue
            }
            if photoState != .started, streamState == .streaming {
                // The stream is running and the photo mode did not come up beside it: the stream's own photo.
                GlassesLog.shared.error("still \(id): the photo mode is \(photoState), taking it in the stream")
                finishStill(id, with: await captureStreamPhoto())
                continue
            }
            holds.insert(.photo)
            restartTask?.cancel()
            restartTask = nil
            await setStreamAside(camera)
            guard await photoModeIsUp(on: camera, startingAfresh: request.attempts > 0), self.camera === camera else {
                GlassesLog.shared.error("still \(id): not taken, the photo mode is \(photoState)")
                finishStill(id, with: nil)
                continue
            }
            guard let index = stills.firstIndex(where: { $0.id == id }) else { continue }
            stills[index].asked = (.now, .now)
            stillLastActivity = .now
            camera.photo.capturePhoto(resolution: request.size.resolution, quality: request.size.quality)
            GlassesLog.shared.note("still \(id): asked for (\(request.size.summary)) \(Self.seconds(since: request.wanted)) after the tap; \(stills.count) in the queue")
            watchStills()
        }
    }

    /// Ends still `id` with `data`, or without a photo, and moves the queue on: the next refused one is asked for
    /// again, and with the queue empty the camera leaves the session and listening comes back.
    private func finishStill(_ id: Int, with data: Data?) {
        guard let index = stills.firstIndex(where: { $0.id == id }) else { return }
        let request = stills.remove(at: index)
        if data != nil { request.progress(1) }
        request.continuation.resume(returning: data)
        stillLastActivity = .now
        Task { [weak self] in
            guard let self else { return }
            if self.stills.isEmpty {
                await self.endStills()
            } else {
                await self.askForStills()
            }
        }
    }

    /// The queue is empty: the camera leaves the session. The stream could not be started again on it (a "Critical
    /// error" each time on the glasses, 2026-11-12, where a new camera then streamed within two seconds), and
    /// Speech, when the lens asks for a name, failed while it was there.
    private func endStills() async {
        guard stills.isEmpty, !isEndingStills, holds.remove(.photo) != nil else { return }
        isEndingStills = true
        defer { isEndingStills = false }
        stillWatch?.cancel()
        stillWatch = nil
        resumeCueOwed = true
        GlassesLog.shared.note("stills: none left, the camera leaves the session")
        await takeCameraOff()
        await cameraStopped?.value
        if holds.isEmpty { scheduleRestart(after: .zero) }
    }

    /// Gives up on the oldest still when nothing of any has crossed for `stillQuiet`.
    private func watchStills() {
        guard stillWatch == nil else { return }
        stillWatch = Task { [weak self] in
            while let self, !Task.isCancelled, !self.stills.isEmpty {
                if let head = self.stills.first(where: { $0.asked != nil }), let last = self.stillLastActivity,
                   ContinuousClock.now - last > Self.stillQuiet {
                    if let total = head.total, head.firstBytes != nil { self.abandonedTotals.insert(total) }
                    GlassesLog.shared.error("still \(head.id): not taken, nothing crossed for \(Self.seconds(Self.stillQuiet)) (\(max(head.tenth, 0) * 10)% had)")
                    self.finishStill(head.id, with: nil)
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            if !Task.isCancelled { self?.stillWatch = nil }
        }
    }

    /// Gives the photo mode the time a camera that is coming up needs: the stream's start (`startTimeout`), then the
    /// mode's own (`photoStartTimeout`).
    private func waitForPhotoMode() async {
        guard photoState != .started || camera == nil, chunkContinuation != nil else { return }
        let began = ContinuousClock.now
        while photoState != .started || camera == nil, ContinuousClock.now - began < Self.startTimeout {
            // A camera on its way: the stream starting, or a new camera being added after the last photos or a clip.
            let streamComing = isStarting || restartTask != nil || isEndingStills
            let modeComing = camera != nil && streamState == .streaming && ContinuousClock.now - began < Self.photoStartTimeout
            // With its stream stopped, a camera's photo mode is started again by the still itself.
            guard streamComing || modeComing else { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        GlassesLog.shared.note("the photo waited \(Self.seconds(since: began)) for the camera (stream \(streamState), photo mode \(photoState))")
    }

    /// Whether the photo mode is started on `camera`, starting it if it went down with the stream: a camera that
    /// was streaming a moment ago is awake, which is all the mode needs. Gives it `photoStartTimeout`.
    private func photoModeIsUp(on camera: Camera, startingAfresh: Bool = false) async -> Bool {
        if startingAfresh, photoState == .started {
            // It says started and refused a still: down and up again.
            camera.photo.stop()
            let stopping = ContinuousClock.now
            while photoState != .stopped, ContinuousClock.now - stopping < .seconds(2) {
                try? await Task.sleep(for: .milliseconds(50))
            }
            // A mode that was already down publishes nothing when it is stopped: what it last said is not believed.
            publishedPhotoState.withLock { $0 = .stopped }
        }
        if photoState == .started { return true }
        let began = ContinuousClock.now
        GlassesLog.shared.note("photo mode: \(photoState) with the stream down, starting it")
        // Asked again while it stays stopped: a start that lands while the mode is still going down is lost.
        var asked: ContinuousClock.Instant?
        while photoState != .started, self.camera === camera, ContinuousClock.now - began < Self.photoStartTimeout {
            if photoState == .stopped, asked.map({ ContinuousClock.now - $0 > .milliseconds(750) }) ?? true {
                asked = .now
                photoStartRequested = true
                camera.photo.start()
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return photoState == .started && self.camera === camera
    }

    /// A JPEG taken in the stream; nil when the stream is not running or no photo came within `photoTimeout`.
    private func captureStreamPhoto() async -> Data? {
        guard let camera, streamState == .streaming else {
            GlassesLog.shared.error("photo not taken: the stream is \(streamState)")
            return nil
        }
        let began = ContinuousClock.now
        let stream = camera.stream
        guard let taken = await photo(quietFor: Self.photoTimeout, atMost: Self.photoTimeout, asking: { stream.capturePhoto(format: .jpeg) }) else {
            GlassesLog.shared.error("photo not taken in the stream after \(Self.seconds(since: began))")
            return nil
        }
        GlassesLog.shared.note("photo taken in the stream in \(Self.seconds(since: began)) (\(taken.count) bytes)")
        return taken
    }

    /// Asks for a photo with `ask` (false when the glasses refuse at once) and waits for it while bytes keep crossing:
    /// until the link has been quiet for `quiet`, or `limit` in all. The camera's listeners deliver it
    /// (`photoArrived(_:)`), whichever of the stream and the photo mode it came from.
    private func photo(quietFor quiet: Duration, atMost limit: Duration, asking ask: () -> Bool) async -> Data? {
        let began = ContinuousClock.now
        photoRequestedAt = began
        photoLastActivity = began
        photoWaits += 1
        let id = photoWaits
        return await withCheckedContinuation { continuation in
            // One photo at a time: they carry no request, so an earlier wait gives way to this one.
            photoWait?.continuation.resume(returning: nil)
            photoWait = (id, continuation)
            guard ask() else {
                endPhotoWait(id, with: nil)
                return
            }
            Task { [weak self] in
                while let self, self.photoWait?.id == id {
                    let now = ContinuousClock.now
                    if now - (self.photoLastActivity ?? began) > quiet || now - began > limit {
                        self.endPhotoWait(id, with: nil)
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }
    }

    /// Ends capture `id`'s wait with `photo`, or with nothing once its time is up; a wait already over is left alone.
    private func endPhotoWait(_ id: Int, with photo: Data?) {
        guard let wait = photoWait, wait.id == id else { return }
        photoWait = nil
        wait.continuation.resume(returning: photo)
    }

    /// A photo came on the stream: the waiting capture's. One no capture waits for is late (or the glasses' own
    /// shutter): the log says by how much, which is how long the wait would have to be.
    private func photoArrived(_ photo: Data) {
        if let wait = photoWait {
            endPhotoWait(wait.id, with: photo)
            return
        }
        let late = photoRequestedAt.map { "\(Self.seconds(since: $0)) after it was asked for" } ?? "none was asked for"
        GlassesLog.shared.error("a photo arrived with no capture waiting: \(late) (\(photo.count) bytes)")
    }

    /// `data` as a JPEG: the album names its files .jpg. The glasses may send HEIF, which is re-encoded.
    private nonisolated static func jpeg(_ data: Data) -> Data? {
        if data.starts(with: [0xFF, 0xD8]) { return data }
        return UIImage(data: data)?.jpegData(compressionQuality: 0.9)
    }

    /// The pixels of `data` as "W×H", for the log; "?" for data that is no picture.
    private nonisolated static func pixelSize(of data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return "?" }
        return "\(width)×\(height)"
    }

    // MARK: - A capture

    /// "Capture a sighting" has the camera and the glasses' microphones from its tap until the bird's name is heard
    /// or left for later: listening stays off for it, so nothing competes with the still for the camera or with the
    /// name for the microphones (the maintainer's flow, 2026-11-12). The photo's own path stops the stream; this
    /// keeps it stopped once the photo is in. The chunk stream stays open, as for a clip, and the silence is filled
    /// in when listening returns.
    func beginCapture() async {
        guard chunkContinuation != nil, holds.insert(.capture).inserted else { return }
        GlassesLog.shared.note("capture: listening paused")
        // A photo on its way sets the stream aside itself; one that will be taken in the stream (no photo mode)
        // needs the stream, and sets it aside when it is in.
        if !isTakingPhoto, photoState == .started, let camera { await setStreamAside(camera) }
    }

    /// The capture no longer needs the camera or the microphones (the photo is named, left for later, or was never
    /// taken): listening comes back.
    func endCapture() async {
        guard holds.remove(.capture) != nil else { return }
        GlassesLog.shared.note("capture: listening resumes")
        bringStreamBack()
    }

    /// Stops the stream on `camera`, which stays on the session with its photo mode, and waits for it to let go of
    /// the camera: `stop()` returns at once, and a still asked for before the stream is down is refused.
    private func setStreamAside(_ camera: Camera) async {
        guard self.camera === camera else { return }
        // Also when the stream has stopped by itself: it is off on a camera that is still on the session, and
        // bringing it back starts it there.
        streamSetAside = true
        guard camera.stream.state != .stopped else { return }
        let began = ContinuousClock.now
        heldSince.withLock { $0 = $0 ?? .now }
        // The add's viewfinder says it is waiting rather than showing a picture that no longer moves.
        latestVideoFrame.withLock { $0 = nil }
        camera.stream.stop()
        while camera.stream.state != .stopped, ContinuousClock.now - began < Self.setAsideTimeout {
            try? await Task.sleep(for: .milliseconds(50))
        }
        GlassesLog.shared.note("stream set aside (\(Self.seconds(since: began)), \(camera.stream.state))")
    }

    /// Starts listening again once nothing holds the camera, on a new camera: a stream that was set aside could not be
    /// started again on its own camera on the glasses ("Critical error", every time on 2026-11-12), and a new camera
    /// streamed within two seconds.
    private func bringStreamBack() {
        guard holds.isEmpty, chunkContinuation != nil else { return }
        guard camera == nil || streamSetAside else { return }
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            guard let self else { return }
            await self.takeCameraOff()
            guard !Task.isCancelled, self.holds.isEmpty else { return }
            await self.restartAfterHold()
            if !Task.isCancelled { self.restartTask = nil }
        }
    }

    /// Lets go of the photo mode with its camera.
    private func releasePhotoMode() async {
        let tokens = photoTokens
        photoTokens = ListenerTokenBag()
        await tokens.cancelAll()
        publishedPhotoState.withLock { $0 = .stopped }
        loggedPhotoState = .stopped
        photoStartRequested = false
        streamSetAside = false
        // No still comes from a camera that is off the session.
        if !stills.isEmpty {
            GlassesLog.shared.error("stills: \(stills.count) not taken, the camera left the session")
            failStills()
            holds.remove(.photo)
        }
    }

    // MARK: - Keeping the stream up

    /// The stream should be running now (`reason` names the moment, for the log): a camera that is off with nothing
    /// holding it and no restart under way, or one that has not delivered audio for `audioStall`, is replaced by a
    /// fresh one. A stream that is still starting is left to start, for `startAllowance`. Leaves a session that is
    /// not started (paused, ended) to the run, and a stream the toolkit paused to the toolkit.
    func ensureStreaming(_ reason: String) async {
        guard holds.isEmpty, restartTask == nil, chunkContinuation != nil, let session, session.state == .started else { return }
        let quiet = lastAudio.withLock { $0 }.map { ContinuousClock.now - $0 }
        let stalled: String
        if camera == nil {
            stalled = "the camera is off"
        } else if streamState == .paused {
            return
        } else if let quiet, quiet > (isStarting ? Self.startAllowance : Self.audioStall) {
            stalled = "no audio for \(Self.seconds(quiet)), the stream is \(streamState)"
        } else {
            return
        }
        GlassesLog.shared.error("stream down at the \(reason) (\(stalled)): restarting")
        await takeCameraOff()
        scheduleRestart(after: .zero)
    }

    /// Whether the current camera's stream is on its way up and has not streamed yet.
    private var isStarting: Bool {
        switch streamState {
        case .waitingForDevice, .starting: true
        default: false
        }
    }

    // MARK: - Holding the stream for a clip

    /// Takes the camera off the session for a clip, so the glasses' speakers play it. The session, the lens on it and
    /// the chunk stream stay; a restart already pending is called off. The clip does not wait for the camera to stop.
    func holdForPlayback() async {
        restartTask?.cancel()
        restartTask = nil
        guard holds.insert(.playback).inserted else { return }
        GlassesLog.shared.note("holding the stream for a clip")
        await takeCameraOff()
    }

    /// The clip is over: the camera goes back on the session after `restartDelay`, unless another clip holds it
    /// first or the session has gone (a doff's resume puts the camera back itself).
    func releaseAfterPlayback() {
        guard holds.remove(.playback) != nil else { return }
        scheduleRestart(after: Self.restartDelay)
    }

    /// Takes the camera off the session while the glasses listen for a bird's name (issue #194), when the switch says
    /// Speech does not run beside the stream: as for a clip, the session, the lens and the chunk stream stay.
    func holdForDictation() async {
        restartTask?.cancel()
        restartTask = nil
        guard holds.insert(.dictation).inserted else { return }
        GlassesLog.shared.note("holding the stream for a dictation")
        await takeCameraOff()
        // Speech starts once the camera is off the session, not while it is on its way off.
        await cameraStopped?.value
    }

    /// The dictation is over: the camera goes back on the session at once, unless a clip holds it.
    func releaseAfterDictation() {
        guard holds.remove(.dictation) != nil else { return }
        scheduleRestart(after: .zero)
    }

    /// Takes the camera off the session, which keeps the lens on it, and the chunk stream open; the silence until the
    /// stream is back is filled in when it returns.
    private func takeCameraOff() async {
        guard let camera else { return }
        self.camera = nil
        heldSince.withLock { $0 = $0 ?? .now }
        await releaseListeners()
        await releasePhotoMode()
        // The viewfinder says it is waiting rather than showing a picture that no longer moves.
        latestVideoFrame.withLock { $0 = nil }
        cameraStopped = Self.stopping(camera)
        handle(.streamState(.stopped))
    }

    /// Puts the stream back after `delay` once nothing holds the camera.
    private func scheduleRestart(after delay: Duration) {
        guard holds.isEmpty else { return }
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            await self.restartAfterHold()
            if !Task.isCancelled { self.restartTask = nil }
        }
    }

    /// Puts a fresh camera on the session and waits for its stream, trying again with another one if it does not
    /// start, and again after `retryDelay` once `restartAttempts` have failed. Gives up quietly when cancelled (a
    /// clip, a photo, or the run stopping) or when the session has gone.
    private func restartAfterHold() async {
        await cameraStopped?.value
        cameraStopped = nil
        // The sound for listening coming back, while the stream is still off and the glasses can play it.
        if resumeCueOwed, holds.isEmpty, let cues {
            resumeCueOwed = false
            await cues.play(.listening)
        }
        for attempt in 1...Self.restartAttempts {
            guard !Task.isCancelled, holds.isEmpty, camera == nil, let session, let continuation = chunkContinuation else { return }
            guard await session.waitUntilStarted(timeout: Self.sessionTimeout) else {
                GlassesLog.shared.error("stream restart: the session is \(String(describing: session.state)), not started")
                // A session the glasses paused may come back; one that ended is suspended by the run, which ends this.
                retryLater(on: session)
                return
            }
            guard !Task.isCancelled, holds.isEmpty, camera == nil, self.session === session else { return }
            GlassesLog.shared.note("stream restart, attempt \(attempt)")
            let began = ContinuousClock.now
            let camera: Camera
            do {
                camera = try attachCamera(to: session, feeding: continuation, start: false)
            } catch {
                GlassesLog.shared.error("stream restart, attempt \(attempt): \(error.localizedDescription)")
                try? await Task.sleep(for: Self.restartDelay)
                continue
            }
            // The stream reports `.stopped` only once it has left it: a stream the glasses reject stops within a
            // second, and waiting out the timeout after that only keeps the wearer waiting (#46).
            let left = Once()
            let streaming = await camera.stream.statePublisher.waitUntil(timeout: Self.startTimeout, after: {
                camera.stream.start()
            }) { state in
                switch state {
                case .streaming: return true
                case .stopped: return left.claim() ? nil : false
                default:
                    _ = left.claim()
                    return nil
                }
            }
            // Another clip or the run's stop may have taken this camera off during the wait.
            guard self.camera === camera else { return }
            if streaming {
                GlassesLog.shared.note("stream back (attempt \(attempt), \(Self.seconds(since: began)))")
                return
            }
            GlassesLog.shared.error("stream restart, attempt \(attempt): the stream did not start (\(Self.seconds(since: began)))")
            self.camera = nil
            await releaseListeners()
            await Self.stopping(camera).value
            handle(.streamState(.stopped))
        }
        handle(.streamError(.internalError))
        if let session { retryLater(on: session) }
    }

    /// Tries the restart again after `retryDelay` while `session` is still the source's, rather than leave the run
    /// without listening.
    private func retryLater(on session: DeviceSession) {
        guard !Task.isCancelled, self.session === session, chunkContinuation != nil else { return }
        GlassesLog.shared.error("the stream did not come back; trying again in \(Self.seconds(Self.retryDelay))")
        scheduleRestart(after: Self.retryDelay)
    }

    /// Releases the current camera's listeners, and a capture waiting on it; a camera added meanwhile has its own.
    private func releaseListeners() async {
        // No photo comes from a camera that is going: its capture goes on with the frame from the tap.
        if let wait = photoWait { endPhotoWait(wait.id, with: nil) }
        let tokens = cameraTokens
        cameraTokens = ListenerTokenBag()
        await tokens.cancelAll()
    }

    /// `duration` for the log, to a tenth of a second.
    private static func seconds(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return String(format: "%.1f s", seconds)
    }

    private static func seconds(since instant: ContinuousClock.Instant) -> String {
        seconds(ContinuousClock.now - instant)
    }

    /// Stops `camera` and finishes once it reports `.stopped`, or after `stopTimeout`. One that already reports
    /// `.stopped` (a capability that never started) is still told to stop, but not waited for.
    private static func stopping(_ camera: Camera) -> Task<Void, Never> {
        Task {
            guard camera.state != .stopped else {
                camera.stop()
                return
            }
            _ = await camera.statePublisher.waitUntil(timeout: stopTimeout, after: { camera.stop() }) { state in
                state == .stopped ? true : nil
            }
        }
    }

    private func handle(_ event: Event) {
        switch event {
        case .streamState(let state) where state != streamState: GlassesLog.shared.note("stream: \(state)")
        case .sessionState(let state) where state != sessionState: GlassesLog.shared.note("session: \(state)")
        case .streamError(let error): GlassesLog.shared.error("stream error: \(error.description)")
        case .sessionError(let error): GlassesLog.shared.error("session error: \(error)")
        default: break
        }
        switch event {
        case .sessionState(let state): sessionState = state
        case .streamState(let state):
            // The audio has `audioStall` from here, not from when the camera was added: a start can take longer.
            if state == .streaming, streamState != .streaming, camera != nil { lastAudio.withLock { $0 = .now } }
            streamState = state
            if state == .streaming { startPhotoModeIfNeeded() }
        case .sessionError, .streamError: break
        }
        eventContinuation.yield(event)
    }
}

/// How large a photo the glasses are asked for, which the birder chooses in Settings (2026-11-12, the maintainer's
/// call: full detail by default, with smaller ones for a birder who finds the wait too long). Listening is off until
/// the photo has crossed to the phone, and the link carried 30 to 40 KB a second: a full photo was 1.3 to 1.9 MB as
/// sent, most of a minute; the 1080p one was 280 KB and took ten seconds. The smallest has not been timed.
nonisolated enum GlassesPhotoSize: String, CaseIterable, Identifiable, Sendable {
    case full
    case standard
    case small

    static let key = "glassesPhotoSize"
    static let byDefault = GlassesPhotoSize.full

    var id: String { rawValue }

    var title: String {
        switch self {
        case .full: "Full detail"
        case .standard: "Standard"
        case .small: "Small"
        }
    }

    /// What the choice costs and gives, under the picker.
    var detail: String {
        switch self {
        case .full: "The sharpest photo (12 megapixels) and the longest wait: it can take up to a minute to reach your phone, and listening pauses until it has."
        case .standard: "A smaller photo that reaches your phone in about ten seconds. Listening pauses until it has."
        case .small: "The quickest photo to reach your phone, with the least detail. Listening pauses until it has."
        }
    }

    var resolution: PhotoResolution {
        switch self {
        case .full: .full
        case .standard: .large
        case .small: .medium
        }
    }

    var quality: PhotoQuality {
        switch self {
        case .full: .high
        case .standard, .small: .medium
        }
    }

    /// For the camera log.
    var summary: String { "\(rawValue): \(resolution.rawValue), \(quality.rawValue) quality" }

    static func current(_ defaults: UserDefaults = .standard) -> GlassesPhotoSize {
        defaults.string(forKey: key).flatMap(GlassesPhotoSize.init(rawValue:)) ?? byDefault
    }
}

/// A still asked for and not yet in.
private struct StillRequest {
    let id: Int
    let size: GlassesPhotoSize
    /// Told how much of it has crossed.
    let progress: @MainActor @Sendable (Double) -> Void
    let continuation: CheckedContinuation<Data?, Never>
    /// When the wearer tapped.
    let wanted: ContinuousClock.Instant
    /// When the glasses were asked for it, by the clock and by the calendar; nil until they are, and again after a
    /// refusal.
    var asked: (clock: ContinuousClock.Instant, date: Date)?
    /// How many times the glasses have refused it.
    var attempts = 0
    var firstBytes: ContinuousClock.Instant?
    /// The last tenth of it told.
    var tenth = -1
    /// The size of its transfer.
    var total: UInt64?
}

/// True the first time it is claimed, from any thread.
private nonisolated final class Once: Sendable {
    private let claimed = Mutex(false)

    func claim() -> Bool {
        claimed.withLock { claimed in
            defer { claimed = true }
            return !claimed
        }
    }
}

extension AudioChunk {
    /// Silence lasting `span` at `sampleRate`, timed to end where `next` begins; nil for a span under one sample.
    nonisolated static func silence(lasting span: Duration, at sampleRate: Int, before next: AudioChunk) -> AudioChunk? {
        let seconds = Double(span.components.seconds) + Double(span.components.attoseconds) / 1e18
        let count = Int(seconds * Double(sampleRate))
        guard count > 0 else { return nil }
        return AudioChunk(samples: [Float](repeating: 0, count: count), sampleRate: sampleRate, presentationTime: next.presentationTime - seconds)
    }
}
