import Foundation
import Identification
import MWDATCamera
import MWDATCore
import UIKit

/// A camera frame kept for a sighting, encoded when the sighting is written (issue #9).
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
/// frame the wearer confirmed on with the sighting; sources without a camera keep none. The source outlives the
/// device session it streams on (issue #10): when the glasses end the session (doff, link loss) the run suspends
/// it and resumes it on the next session, and the chunk stream the engine reads stays open in between.
@MainActor
protocol FrameKeepingAudioSource: AudioSource {
    var latestFrame: CameraFrame? { get }
    /// The session ended under the stream: release what was on it, keep the chunk stream open.
    func suspend() async
    /// Continue the same chunk stream on `session`.
    func resume(on session: DeviceSession) async throws
}
