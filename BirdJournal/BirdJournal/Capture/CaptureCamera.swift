import Album
import Foundation
import Observation
import SwiftUI

/// A photo to name (issue #186, of #185): the picture as the capture camera wrote it, and when; or, since #192, one the birder
/// chose from their library, as its file is. Naming it makes it a sighting's original photo.
nonisolated struct CapturedPhoto: Identifiable, Equatable, Sendable {
    let id = UUID()
    /// The file's bytes as the camera or the library gave them: a JPEG or a HEIC, never re-encoded.
    let data: Data
    /// The time its sighting takes: when the shutter was pressed.
    let takenAt: Date
    /// Where the picture itself says it was taken, which only a photo chosen from the library can (issue #192): its sighting
    /// is recorded there. Nil for the camera's own photos and for a library photo that carries no place: the sighting then
    /// takes the place the birder is at.
    var place: Coordinate? = nil
    var origin = Origin.camera

    /// How the photo came to the app.
    enum Origin: Equatable, Sendable {
        /// Taken with the capture camera, just now.
        case camera
        /// Chosen from the birder's library (issue #192). `takenAt` is the picture's own date when it carries one, else the
        /// time it was chosen.
        case library(carriesDate: Bool)
    }
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
/// Its controls (issue #187) are here too: the zoom with the lens steps the phone has, and focus where the birder taps. There
/// is no flash to control: no camera behind this fires one.
@MainActor
protocol CaptureCamera: AnyObject, Observable {
    var state: CaptureCameraState { get }
    /// Asks for the camera on first use and opens it. Safe to call again.
    func start() async
    /// Closes the camera; nothing is kept running behind the naming sheet or the run.
    func stop()
    /// Takes one photo with the flash off, then lets the camera focus by itself again.
    func takePhoto() async throws -> CapturedPhoto
    /// What the camera sees, to fill the viewfinder.
    var viewfinder: AnyView { get }

    /// The lens steps this camera has, how far it zooms and where the zoom stands: `.fixed` until the camera is open.
    var zoom: CaptureZoom { get }
    /// Zooms to `factor`, as a birder reads it, kept within the camera's range. A lens button asks for it smoothly, so the
    /// picture glides there; a pinch asks for each factor at once, so the picture stays under the fingers.
    func setZoom(_ factor: Double, smoothly: Bool)
    /// Where in the viewfinder focus and exposure are held, (0, 0) being its top left corner; nil while the camera chooses
    /// for itself, as it does until a tap and again after the shot.
    var focusPoint: UnitPoint? { get }
    /// Focuses and exposes at a point of the viewfinder, and holds there.
    func focus(at point: UnitPoint)
}

extension EnvironmentValues {
    /// Makes the camera a capture opens: the phone's own, unless a debug launch flag or a test stands one in.
    @Entry var makeCaptureCamera: @MainActor () -> any CaptureCamera = { CaptureCameras.forApp() }
}

enum CaptureCameras {
    /// The phone's rear camera. In debug builds `-fakeCamera ready|denied|unavailable` stands one in (`StandInCaptureCamera`),
    /// for the simulator, which has no camera, and for a UI test, which couldn't answer the permission prompt. For a
    /// screenshot, `-fakeCameraZoom 2.6` opens it zoomed and `-fakeCameraFocus 0.3,0.4` with focus held at that point.
    static func forApp() -> any CaptureCamera {
        #if DEBUG
        let defaults = UserDefaults.standard
        if let mode = defaults.string(forKey: "fakeCamera").flatMap(StandInCaptureCamera.Mode.init(rawValue:)) {
            let zoom = defaults.object(forKey: "fakeCameraZoom") == nil ? nil : defaults.double(forKey: "fakeCameraZoom")
            let focus = (defaults.string(forKey: "fakeCameraFocus") ?? "").split(separator: ",").compactMap { Double($0) }
            return StandInCaptureCamera(mode, opensAt: zoom, focusedAt: focus.count == 2 ? UnitPoint(x: focus[0], y: focus[1]) : nil)
        }
        #endif
        return PhoneCaptureCamera()
    }
}

extension UnitPoint {
    /// The nearest point inside the picture: a tap on the viewfinder's very edge can land a hair outside it.
    var withinThePicture: UnitPoint {
        UnitPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
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

    /// An iPhone 17 Pro's rear camera, as AVFoundation describes it: the ultra-wide, the wide and the telephoto, each with a
    /// full-quality crop at twice its own start, read at half the camera's own factor. So: 0.5, 1, 2, 4 and 8.
    nonisolated static let iPhone17Pro = RearCameraFacts(
        minimum: 1, maximum: 189,
        lenses: [.init(start: 1, fullQualityCrops: [2]), .init(start: 2, fullQualityCrops: [2]), .init(start: 8, fullQualityCrops: [2])],
        displayMultiplier: 0.5
    )

    private(set) var state = CaptureCameraState.starting
    /// How many photos it has taken, for a test to read.
    private(set) var photosTaken = 0
    /// The zoom it has been set to: what a test asserts a lens button or a pinch did.
    private(set) var zoom = CaptureZoom.fixed
    private(set) var focusPoint: UnitPoint?
    /// A test holds each photo back until `deliverPhoto()`, as a real camera takes a moment over one.
    @ObservationIgnored var holdsPhoto = false
    @ObservationIgnored private var held: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private let mode: Mode
    @ObservationIgnored private let lenses: RearCameraFacts
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let opening: (zoom: Double?, focus: UnitPoint?)

    /// - Parameters:
    ///   - lenses: the rear camera it stands in for; an iPhone 17 Pro's unless a test says otherwise.
    ///   - zoom: where its zoom stands when it opens, for a screenshot; the wide lens otherwise.
    ///   - focus: where focus is held when it opens, for a screenshot; nowhere otherwise.
    init(
        _ mode: Mode = .ready, lenses: RearCameraFacts = StandInCaptureCamera.iPhone17Pro, opensAt zoom: Double? = nil, focusedAt focus: UnitPoint? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.mode = mode
        self.lenses = lenses
        self.opening = (zoom, focus)
        self.now = now
    }

    func start() async {
        state = switch mode {
        case .ready: .ready
        case .denied: .denied
        case .unavailable: .unavailable
        }
        if state == .ready, zoom == .fixed {
            zoom = CaptureZoom(lenses)
            if let factor = opening.zoom { zoom.set(factor) }
            focusPoint = opening.focus?.withinThePicture
        }
    }

    func stop() {
        state = .starting
    }

    func takePhoto() async throws -> CapturedPhoto {
        guard state == .ready else { throw CaptureFailure.notReady }
        photosTaken += 1
        focusPoint = nil
        let takenAt = now()
        if holdsPhoto { await withCheckedContinuation { held.append($0) } }
        return CapturedPhoto(data: DebugSeeds.frameJPEG(), takenAt: takenAt)
    }

    /// Hands over the photos held back.
    func deliverPhoto() {
        let waiting = held
        held = []
        for continuation in waiting { continuation.resume() }
    }

    func setZoom(_ factor: Double, smoothly: Bool) {
        guard state == .ready else { return }
        zoom.set(factor)
    }

    func focus(at point: UnitPoint) {
        guard state == .ready else { return }
        focusPoint = point.withinThePicture
    }

    /// A drawing that zooms: the bird grows and shrinks with the factor, so a lens button's effect shows on the simulator.
    var viewfinder: AnyView {
        AnyView(
            ZStack {
                Color(red: 0.35, green: 0.55, blue: 0.3)
                Image(systemName: "bird.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.white.opacity(0.9))
                    .scaleEffect(min(max(zoom.factor, 0.5), 8))
                    // Zoomed in it is larger than the viewfinder, and a clipped picture still takes touches.
                    .allowsHitTesting(false)
            }
            .clipped()
            .accessibilityHidden(true)
        )
    }
}
#endif
