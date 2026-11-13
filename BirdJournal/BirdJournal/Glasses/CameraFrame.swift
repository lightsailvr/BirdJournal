import Foundation
import Identification
import MWDATCamera
import MWDATCore
import UIKit

/// A camera frame kept for a sighting, encoded when the sighting is written (issue #9), or shown on the viewfinder.
nonisolated struct CameraFrame: Sendable {
    /// The frame as an image, or nil if it cannot be decoded. Safe to call off the main actor.
    let image: @Sendable () -> UIImage?

    init(image: @escaping @Sendable () -> UIImage?) {
        self.image = image
    }

    /// A frame known only as a JPEG (the tests' frames).
    init(jpegData: @escaping @Sendable () -> Data?) {
        self.init { jpegData().flatMap(UIImage.init(data:)) }
    }

    init(_ frame: VideoFrame) {
        self.init { frame.makeUIImage() }
    }

    /// The frame as a JPEG, or nil if it cannot be decoded. Safe to call off the main actor.
    nonisolated func jpegData() -> Data? {
        image()?.jpegData(compressionQuality: 0.85)
    }
}

/// An audio source that also keeps its camera's most recent frame: the glasses stream. The listening run stores the
/// frame the wearer confirmed on with the sighting; sources without a camera keep none. The source outlives the
/// device session it streams on (issue #10): when the glasses end the session (doff, link loss) the run suspends
/// it and resumes it on the next session, and the chunk stream the engine reads stays open in between.
@MainActor
protocol FrameKeepingAudioSource: AudioSource {
    var latestFrame: CameraFrame? { get }
    /// A photo from the camera as a JPEG, nil when none came (no camera, a failure, a timeout).
    func capturePhoto() async -> Data?
    /// As `capturePhoto()`; `progress` is told how much of the photo has crossed to the phone, first when the camera
    /// has it, which on the glasses is some seconds before it has all crossed.
    func capturePhoto(progress: @escaping @MainActor @Sendable (Double) -> Void) async -> Data?
    /// The lens needs the stream now (`reason`: the species list, the viewfinder): put it back if it stopped or
    /// stalled with nothing holding it.
    func ensureStreaming(_ reason: String) async
    /// Gives up every photo asked for and not yet in: their `capturePhoto` calls return nil.
    func cancelPhotos() async
    /// "Capture a sighting" needs the camera for itself: stop listening and bring up the capture camera, whose frames
    /// are then `latestFrame` and whose photo `capturePhoto()` takes.
    func beginCapture() async
    /// The capture no longer needs the camera or the glasses' microphones: listening comes back.
    func endCapture() async
    /// The session ended under the stream: release what was on it, keep the chunk stream open.
    func suspend() async
    /// Continue the same chunk stream on `session`.
    func resume(on session: DeviceSession) async throws
}

extension FrameKeepingAudioSource {
    /// A source whose photo is there at once (the stand-ins) has no moment in between to tell.
    func capturePhoto(progress: @escaping @MainActor @Sendable (Double) -> Void) async -> Data? {
        await capturePhoto()
    }

    /// A source whose photos are there at once has none to give up.
    func cancelPhotos() async {}

    /// A source with one camera for everything (the stand-ins) has nothing to switch.
    func beginCapture() async {}
    func endCapture() async {}
}
