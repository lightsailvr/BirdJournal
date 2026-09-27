import CoreMedia
import Foundation
import Identification
import MWDATCamera
import MWDATCore
import Synchronization

/// Ambient audio from the glasses, which only arrives in-band on a camera stream (DECISIONS.md, "Toolkit facts").
/// Video runs at the lowest resolution and frame rate to save battery; frames are not used for identification, but
/// the most recent one is kept so a sighting can store what the wearer was looking at (issue #9).
///
/// A pause the toolkit reports (`.paused` on the session and stream) is left to it to resume. A session the glasses
/// end (a doff ends it and drops the link, DECISIONS.md phase A) is survived instead (issue #10): the run calls
/// `suspend()`, which drops the camera but keeps the chunk stream open so the engine waits rather than ends, and
/// `resume(on:)` with the next session, which continues the same chunk stream.
///
/// Explicitly main-actor: conforming to the `Sendable` `AudioSource` protocol would otherwise make the class
/// nonisolated under the target's default main-actor isolation. Single use: create one per listening run.
@MainActor
final class GlassesAudioSource: FrameKeepingAudioSource {
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
    private let eventContinuation: AsyncStream<Event>.Continuation
    private var session: DeviceSession?
    private var camera: Camera?
    private var chunkContinuation: AsyncStream<AudioChunk>.Continuation?
    private let tokens = ListenerTokenBag()
    /// Written straight from the video frame callback; read on confirm.
    private nonisolated let latestVideoFrame = Mutex<VideoFrame?>(nil)

    init(wearables: any WearablesInterface = Wearables.shared, lease: DeviceSessionLease = .own, sampleRate: AudioSampleRate = .rate48000) {
        self.wearables = wearables
        self.lease = lease
        self.sampleRate = sampleRate
        (events, eventContinuation) = AsyncStream.makeStream(of: Event.self)
    }

    /// The most recent video frame the stream delivered, nil until the first one arrives and after `stop()`.
    var latestFrame: CameraFrame? { latestVideoFrame.withLock { $0 }.map(CameraFrame.init) }

    /// The stream configuration: raw video at 360×640 and 2 fps (the toolkit's minimum), PCM mono audio.
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

    /// Adds the camera to `session` and starts its stream into `continuation`.
    private func attachCamera(to session: DeviceSession, feeding continuation: AsyncStream<AudioChunk>.Continuation) throws {
        self.session = session
        guard let camera = try session.addCamera(config: configuration) else {
            throw StartError.cameraUnavailable
        }
        self.camera = camera

        camera.stream.audioFramePublisher.listen { frame in
            let chunk = AudioChunk(buffer: frame.pcmBuffer, presentationTime: frame.presentationTimeStamp.seconds)
            if let chunk { continuation.yield(chunk) }
        }.store(in: tokens)
        camera.stream.videoFramePublisher.listen { [weak self] frame in
            self?.latestVideoFrame.withLock { $0 = frame }
        }.store(in: tokens)
        camera.stream.statePublisher.listen { [weak self] state in
            Task { @MainActor in self?.handle(.streamState(state)) }
        }.store(in: tokens)
        camera.stream.errorPublisher.listen { [weak self] error in
            Task { @MainActor in self?.handle(.streamError(error)) }
        }.store(in: tokens)

        camera.stream.start()
    }

    func stop() async {
        await releaseCamera()
        chunkContinuation?.finish()
        chunkContinuation = nil
        // `events` stays open: a session error delivered just after a failed start must still reach the reader,
        // which cancels its own iteration when done.
    }

    /// The session ended under the stream (doff, link loss): the camera, its listeners and the stale frame go; the
    /// chunk stream stays open for `resume(on:)`.
    func suspend() async {
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

    /// Listeners go first so no frame lands after the chunk stream finishes or the camera is gone.
    private func releaseCamera() async {
        await tokens.cancelAll()
        camera?.stop()
        if lease.isOwned { session?.stop() }
        camera = nil
        session = nil
        latestVideoFrame.withLock { $0 = nil }
        streamState = .stopped
    }

    private func handle(_ event: Event) {
        switch event {
        case .sessionState(let state): sessionState = state
        case .streamState(let state): streamState = state
        case .sessionError, .streamError: break
        }
        eventContinuation.yield(event)
    }
}
