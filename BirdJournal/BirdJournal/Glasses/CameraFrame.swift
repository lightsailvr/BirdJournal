import Foundation
import Identification
import MWDATCamera
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
/// frame the wearer confirmed on with the sighting; sources without a camera keep none.
@MainActor
protocol FrameKeepingAudioSource: AudioSource {
    var latestFrame: CameraFrame? { get }
}
