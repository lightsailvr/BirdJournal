import CoreMedia
import Foundation
import Identification
import MWDATCamera
import MWDATCore
import Synchronization
import UIKit

/// Ambient audio from the glasses, which only arrives in-band on a camera stream (DECISIONS.md, "Toolkit facts").
/// Video runs at the lowest resolution and frame rate to save battery; frames are not used for identification, but
/// the most recent one is kept for the lens's viewfinder and as the stand-in for a sighting's photo (issue #9). The
/// viewfinder shows the listening stream as it is: switching to a sharper stream took the camera off and cost the
/// wearer 10 to 14 s of a blank viewfinder on the glasses (#46), and birds do not wait. The photo itself
/// (`capturePhoto()`) is taken in the stream; a standalone full-resolution still (`fullResolutionPhotos`, off since
/// #46) shares the camera with the stream, so the stream comes off for it and goes back on after, as it does for a clip.
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
final class GlassesAudioSource: FrameKeepingAudioSource, PlaybackStreamHold {
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
    /// When the current camera last delivered audio, or was added if it has not yet: how `ensureStreaming(_:)` tells
    /// a stream that went quiet.
    private nonisolated let lastAudio = Mutex<ContinuousClock.Instant?>(nil)
    /// What has the camera off the session: a clip playing, or a full-resolution photo being taken.
    private enum Hold { case playback, photo }
    private var holds: Set<Hold> = []
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
    /// How long a restarted stream may take to reach `.streaming`; one that stops first has failed already.
    static let startTimeout: Duration = .seconds(8)
    /// How long the session may take to come back to `.started` before a restart.
    static let sessionTimeout: Duration = .seconds(10)
    /// How long after `restartAttempts` failed starts the restart tries again.
    static let retryDelay: Duration = .seconds(10)
    /// How long a running camera may go without audio before `ensureStreaming(_:)` takes it for stalled; audio
    /// arrives about 0.2 s after `.streaming` and then continuously.
    static let audioStall: Duration = .seconds(5)
    /// Whether a sighting's photo is the standalone full-resolution still rather than one taken in the stream. Off
    /// since #46: on the glasses the standalone capture failed and cost 25 s without listening, while the in-stream
    /// photo (1080×1440) keeps the stream running. It is also beta in the toolkit 1.0, and an app using it cannot be
    /// published yet (DECISIONS.md). The Mock Device Kit test turns it on.
    var fullResolutionPhotos = false
    /// How many fresh cameras a full-resolution photo tries (the docs: setup fails intermittently, retry once).
    static let photoAttempts = 2
    /// How long the photo capability may take to start.
    static let photoStartTimeout: Duration = .seconds(5)
    /// How long a photo may take before the sighting goes without it; a full-resolution one crosses Bluetooth.
    static let photoTimeout: Duration = .seconds(4)
    static let fullPhotoTimeout: Duration = .seconds(20)

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
        camera.stream.statePublisher.listen { [weak self] state in
            Task { @MainActor in self?.handle(.streamState(state)) }
        }.store(in: cameraTokens)
        camera.stream.errorPublisher.listen { [weak self] error in
            Task { @MainActor in self?.handle(.streamError(error)) }
        }.store(in: cameraTokens)

        if start { camera.stream.start() }
        return camera
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

    /// A photo from the camera, taken now: the stream's own, or the full-resolution still when
    /// `fullResolutionPhotos` is on; nil when none came.
    func capturePhoto() async -> Data? {
        fullResolutionPhotos ? await captureFullPhoto() : await captureStreamPhoto()
    }

    /// A JPEG taken in the stream; nil when the stream is not running or no photo came within `photoTimeout`.
    private func captureStreamPhoto() async -> Data? {
        guard let camera, streamState == .streaming else {
            GlassesLog.shared.error("photo not taken: the stream is \(streamState)")
            return nil
        }
        let began = ContinuousClock.now
        let photo = PhotoBox()
        var accepted = false
        let taken = await camera.stream.photoDataPublisher.waitUntil(timeout: Self.photoTimeout, after: {
            accepted = camera.stream.capturePhoto(format: .jpeg)
        }) { data in
            photo.data = data.data
            return true
        }
        guard accepted, taken else {
            GlassesLog.shared.error("photo not taken (accepted: \(accepted))")
            return nil
        }
        GlassesLog.shared.note("photo taken in \(Self.seconds(since: began)) (\(photo.data?.count ?? 0) bytes)")
        return photo.data
    }

    /// A still at the sensor's full resolution and high quality. The stream comes off for it (the two share the
    /// camera), a fresh camera starts only its photo capability, and the stream goes back on once it is done; nil
    /// when no photo came after `photoAttempts` cameras.
    private func captureFullPhoto() async -> Data? {
        guard chunkContinuation != nil, session != nil else { return nil }
        restartTask?.cancel()
        restartTask = nil
        holds.insert(.photo)
        await takeCameraOff()
        await cameraStopped?.value
        cameraStopped = nil
        var data: Data?
        for attempt in 1...Self.photoAttempts where data == nil {
            guard let session, chunkContinuation != nil else { break }
            data = await takeFullPhoto(on: session, attempt: attempt)
        }
        holds.remove(.photo)
        scheduleRestart(after: .zero)
        return data
    }

    private func takeFullPhoto(on session: DeviceSession, attempt: Int) async -> Data? {
        let camera: Camera
        do {
            guard let added = try session.addCamera(config: configuration) else { throw StartError.cameraUnavailable }
            camera = added
        } catch {
            GlassesLog.shared.error("full photo, attempt \(attempt): \(error.localizedDescription)")
            return nil
        }
        let photo = camera.photo
        let errors = ListenerTokenBag()
        photo.errorPublisher.listen { error in
            let text = "full photo, attempt \(attempt): \(error.description)"
            Task { @MainActor in GlassesLog.shared.error(text) }
        }.store(in: errors)
        var data: Data?
        let started = await photo.statePublisher.waitUntil(timeout: Self.photoStartTimeout, after: { photo.start() }) { state in
            state == .started ? true : nil
        }
        if started {
            let box = PhotoBox()
            let taken = await photo.photoDataPublisher.waitUntil(timeout: Self.fullPhotoTimeout, after: {
                photo.capturePhoto(resolution: .full, quality: .high)
            }) { captured in
                box.data = captured.imageData
                return true
            }
            if taken, let captured = box.data {
                data = await Task.detached(priority: .userInitiated) { Self.jpeg(captured) }.value
                GlassesLog.shared.note("full photo taken (attempt \(attempt), \(captured.count) bytes)")
            } else {
                GlassesLog.shared.error("full photo, attempt \(attempt): none came")
            }
        } else {
            GlassesLog.shared.error("full photo, attempt \(attempt): the photo capability did not start")
        }
        await errors.cancelAll()
        await Self.stopping(camera).value
        return data
    }

    /// `data` as a JPEG: the album names its files .jpg. The glasses may send HEIF, which is re-encoded.
    private nonisolated static func jpeg(_ data: Data) -> Data? {
        if data.starts(with: [0xFF, 0xD8]) { return data }
        return UIImage(data: data)?.jpegData(compressionQuality: 0.9)
    }

    // MARK: - Keeping the stream up

    /// The stream should be running now (`reason` names the moment, for the log): a camera that is off with nothing
    /// holding it and no restart under way, or one that has not delivered audio for `audioStall`, is replaced by a
    /// fresh one. Leaves a session that is not started (paused, ended) to the run, and a stream the toolkit paused
    /// to the toolkit.
    func ensureStreaming(_ reason: String) async {
        guard holds.isEmpty, restartTask == nil, chunkContinuation != nil, let session, session.state == .started else { return }
        let quiet = lastAudio.withLock { $0 }.map { ContinuousClock.now - $0 }
        let stalled: String
        if camera == nil {
            stalled = "the camera is off"
        } else if streamState == .paused {
            return
        } else if let quiet, quiet > Self.audioStall {
            stalled = "no audio for \(Self.seconds(quiet)), the stream is \(streamState)"
        } else {
            return
        }
        GlassesLog.shared.error("stream down at the \(reason) (\(stalled)): restarting")
        await takeCameraOff()
        scheduleRestart(after: .zero)
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

    /// Takes the camera off the session, which keeps the lens on it, and the chunk stream open; the silence until the
    /// stream is back is filled in when it returns.
    private func takeCameraOff() async {
        guard let camera else { return }
        self.camera = nil
        heldSince.withLock { $0 = $0 ?? .now }
        await releaseListeners()
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

    /// Releases the current camera's listeners; a camera added meanwhile has its own.
    private func releaseListeners() async {
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
        case .streamState(let state): streamState = state
        case .sessionError, .streamError: break
        }
        eventContinuation.yield(event)
    }
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

/// The photo a capture delivered, written from the toolkit's thread and read once the wait is over.
private nonisolated final class PhotoBox: Sendable {
    private let value = Mutex<Data?>(nil)

    var data: Data? {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
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
