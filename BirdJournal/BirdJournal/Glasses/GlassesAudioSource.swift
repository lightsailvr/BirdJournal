import CoreMedia
import Foundation
import Identification
import MWDATCamera
import MWDATCore
import Synchronization
import UIKit

/// A camera frame kept for a sighting, encoded when the sighting is written.
struct CameraFrame: Sendable {
    /// The frame as a JPEG, or nil if it cannot be decoded. Safe to call off the main actor.
    let jpegData: @Sendable () -> Data?

    init(jpegData: @escaping @Sendable () -> Data?) {
        self.jpegData = jpegData
    }

    init(_ frame: VideoFrame) {
        self.init { frame.makeUIImage()?.jpegData(compressionQuality: 0.85) }
    }
}

/// An audio source that also keeps its camera's most recent frame: the glasses stream. The listening run stores the
/// frame the wearer confirmed on with the sighting; sources without a camera keep none.
@MainActor
protocol FrameKeepingAudioSource: AudioSource {
    var latestFrame: CameraFrame? { get }
}

/// Ambient audio from the glasses, which only arrives in-band on a camera stream (DECISIONS.md, "Toolkit facts").
/// Video runs at the lowest resolution and frame rate to save battery; frames are not used for identification, but
/// the most recent one is kept so a sighting can store what the wearer was looking at (issue #9).
///
/// Pauses (doff, touchpad tap) are left to the toolkit: the session and stream report `.paused` and resume on
/// their own, so this source never restarts on a pause.
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
        case permissionDenied(Permission)
        case cameraUnavailable

        var errorDescription: String? {
            switch self {
            case .permissionDenied(let permission): "Glasses \(permission) permission was not granted in Meta AI."
            case .cameraUnavailable: "The glasses camera stream could not be added to the session."
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
        try await ensurePermission(.camera)
        try await ensurePermission(.microphone)

        let session = try await lease.session(wearables: wearables) { session in
            session.statePublisher.listen { [weak self] state in
                Task { @MainActor in self?.handle(.sessionState(state)) }
            }.store(in: tokens)
            session.errorPublisher.listen { [weak self] error in
                Task { @MainActor in self?.handle(.sessionError(error)) }
            }.store(in: tokens)
        }
        self.session = session

        guard let camera = try session.addCamera(config: configuration) else {
            throw StartError.cameraUnavailable
        }
        self.camera = camera

        let (chunks, continuation) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .bufferingNewest(1_024))
        chunkContinuation = continuation
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
        return chunks
    }

    func stop() async {
        // Listeners go first so no frame lands after the chunk stream finishes.
        await tokens.cancelAll()
        camera?.stop()
        if lease.isOwned { session?.stop() }
        camera = nil
        session = nil
        latestVideoFrame.withLock { $0 = nil }
        chunkContinuation?.finish()
        chunkContinuation = nil
        // `events` stays open: a session error delivered just after a failed start must still reach the reader,
        // which cancels its own iteration when done.
    }

    private func handle(_ event: Event) {
        switch event {
        case .sessionState(let state): sessionState = state
        case .streamState(let state): streamState = state
        case .sessionError, .streamError: break
        }
        eventContinuation.yield(event)
    }

    private func ensurePermission(_ permission: Permission) async throws {
        if try await wearables.checkPermissionStatus(permission) == .granted { return }
        guard try await wearables.requestPermission(permission) == .granted else {
            throw StartError.permissionDenied(permission)
        }
    }
}
