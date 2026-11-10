import Foundation
import Observation
import SwiftUI

/// A photo as the capture camera took it (issue #186, of #185): the picture as the camera wrote it, and when. Naming it
/// makes it a sighting's original photo.
nonisolated struct CapturedPhoto: Identifiable, Equatable, Sendable {
    let id = UUID()
    /// The file's bytes as the camera gave them: a JPEG or a HEIC, never re-encoded.
    let data: Data
    let takenAt: Date
}

/// Where the capture camera stands.
enum CaptureCameraState: Equatable {
    /// Asking for the camera the first time, or opening it.
    case starting
    /// The viewfinder is live and the shutter works.
    case ready
    /// The birder has said no to the camera, now or before: only Settings changes that.
    case denied
    /// There is no camera to open: the phone restricts it, or it has none (the simulator).
    case unavailable
}

enum CaptureFailure: Error, Equatable {
    /// The shutter was pressed with no camera open.
    case notReady
    /// The camera took the photo and gave no picture.
    case noPicture
}

/// The camera behind "Capture a sighting": the phone's rear camera (`PhoneCaptureCamera`), or a stand-in for the simulator and
/// the tests (`StandInCaptureCamera`), which have none. The screen reads its state, shows its viewfinder and presses its
/// shutter, and knows nothing of AVFoundation.
///
/// The seam for #187's controls: zoom, the lens steps and tap to focus are added here, and the stand-in reports them.
@MainActor
protocol CaptureCamera: AnyObject, Observable {
    var state: CaptureCameraState { get }
    /// Asks for the camera on first use and opens it. Safe to call again.
    func start() async
    /// Closes the camera; nothing is kept running behind the naming sheet or the run.
    func stop()
    /// Takes one photo with the flash off.
    func takePhoto() async throws -> CapturedPhoto
    /// What the camera sees, to fill the viewfinder.
    var viewfinder: AnyView { get }
}

extension EnvironmentValues {
    /// Makes the camera a capture opens: the phone's own, unless a debug launch flag or a test stands one in.
    @Entry var makeCaptureCamera: @MainActor () -> any CaptureCamera = { CaptureCameras.forApp() }
}

enum CaptureCameras {
    /// The phone's rear camera. In debug builds `-fakeCamera ready|denied|unavailable` stands one in (`StandInCaptureCamera`),
    /// for the simulator, which has no camera, and for a UI test, which couldn't answer the permission prompt.
    static func forApp() -> any CaptureCamera {
        #if DEBUG
        if let mode = UserDefaults.standard.string(forKey: "fakeCamera").flatMap(StandInCaptureCamera.Mode.init(rawValue:)) {
            return StandInCaptureCamera(mode)
        }
        #endif
        return PhoneCaptureCamera()
    }
}

#if DEBUG
/// A camera with no camera: it is ready at once (or denied, or unavailable, as asked), its viewfinder is a drawing, and its
/// shutter hands over the generated frame the seeds use. `-fakeCamera <mode>` puts it behind "Capture a sighting".
@Observable
final class StandInCaptureCamera: CaptureCamera {
    enum Mode: String {
        case ready, denied, unavailable
    }

    private(set) var state = CaptureCameraState.starting
    /// How many photos it has taken, for a test to read.
    private(set) var photosTaken = 0
    @ObservationIgnored private let mode: Mode
    @ObservationIgnored private let now: () -> Date

    init(_ mode: Mode = .ready, now: @escaping () -> Date = Date.init) {
        self.mode = mode
        self.now = now
    }

    func start() async {
        state = switch mode {
        case .ready: .ready
        case .denied: .denied
        case .unavailable: .unavailable
        }
    }

    func stop() {
        state = .starting
    }

    func takePhoto() async throws -> CapturedPhoto {
        guard state == .ready else { throw CaptureFailure.notReady }
        photosTaken += 1
        return CapturedPhoto(data: DebugSeeds.frameJPEG(), takenAt: now())
    }

    var viewfinder: AnyView {
        AnyView(
            ZStack {
                Color(red: 0.35, green: 0.55, blue: 0.3)
                Image(systemName: "bird.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .accessibilityHidden(true)
        )
    }
}
#endif
