import AVFoundation
import Observation
import OSLog
import SwiftUI

/// The phone's rear camera (issue #186): asks for the camera the first time, shows what it sees and takes a photo with the
/// flash off. It adds no audio input and leaves the app's audio session alone, so a phone-microphone run goes on listening
/// behind it.
///
/// Its controls (issue #187): every rear lens the phone has, behind one camera that changes lens as the zoom passes each
/// one's start, so a pinch runs through them without a break; a tap focuses and exposes where it landed until the shot, or
/// until the scene changes, and then the camera chooses for itself again.
///
/// Not exercised by any test beyond the settings of a photo: the simulator has no camera. `StandInCaptureCamera` stands in
/// there, and this is checked on an iPhone.
@Observable
final class PhoneCaptureCamera: CaptureCamera {
    private(set) var state = CaptureCameraState.starting
    private(set) var zoom = CaptureZoom.fixed
    private(set) var focusPoint: UnitPoint?
    @ObservationIgnored private let camera = RearCamera()
    @ObservationIgnored private let points = ViewfinderPoints()
    private static let logger = Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "capture")

    init() {
        // The birder has turned to something else: a focus held on the last bird would be wrong for this one.
        camera.sceneChanged = { [weak self] in
            Task { @MainActor in self?.focusContinuously() }
        }
    }

    func start() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            // The system's prompt, with `NSCameraUsageDescription` saying what the camera is for.
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                state = .denied
                return
            }
        case .denied:
            state = .denied
            return
        case .restricted:
            state = .unavailable
            return
        @unknown default:
            state = .unavailable
            return
        }
        guard let facts = await camera.open() else {
            state = .unavailable
            Self.logger.error("the rear camera did not open")
            return
        }
        // Reopened behind the same screen, the zoom stays where the birder left it.
        if zoom == .fixed {
            zoom = CaptureZoom(facts)
            // What the phone said and what was made of it, to read in Console on a phone no test has run on.
            Self.logger.info("rear camera: \(String(describing: facts), privacy: .public); lens buttons \(String(describing: self.zoom.lenses), privacy: .public), zoom to \(self.zoom.range.upperBound, privacy: .public)")
        }
        camera.zoom(to: zoom.deviceFactor, smoothly: false)
        state = .ready
    }

    func stop() {
        camera.close()
        if state == .ready { state = .starting }
    }

    func takePhoto() async throws -> CapturedPhoto {
        guard state == .ready else { throw CaptureFailure.notReady }
        let data = try await camera.capture(Self.settingsForAPhoto())
        focusContinuously()
        return CapturedPhoto(data: data, takenAt: .now)
    }

    /// What every photo is asked for with. The flash is never part of it: it startles the bird and reaches nothing at that
    /// distance, so nothing in the app can turn it on, and the torch is never lit either.
    nonisolated static func settingsForAPhoto() -> AVCapturePhotoSettings {
        let settings = AVCapturePhotoSettings()
        settings.flashMode = .off
        return settings
    }

    func setZoom(_ factor: Double, smoothly: Bool) {
        guard state == .ready else { return }
        zoom.set(factor)
        camera.zoom(to: zoom.deviceFactor, smoothly: smoothly)
    }

    func focus(at point: UnitPoint) {
        guard state == .ready else { return }
        let point = point.withinThePicture
        focusPoint = point
        camera.focus(at: points.inTheCamera(point))
    }

    private func focusContinuously() {
        guard focusPoint != nil else { return }
        focusPoint = nil
        camera.focus(at: nil)
    }

    var viewfinder: AnyView {
        AnyView(CameraPreview(session: camera.session, device: camera.device, points: points).accessibilityHidden(true))
    }
}

/// Turns a point of the viewfinder into the camera's own terms, which the preview layer knows however the phone is held.
@MainActor
private final class ViewfinderPoints {
    weak var preview: CameraPreview.PreviewView?

    func inTheCamera(_ point: UnitPoint) -> CGPoint {
        guard let preview, !preview.bounds.isEmpty else {
            // No layer to ask: a phone held upright, whose sensor lies on its side.
            return CGPoint(x: point.y, y: 1 - point.x)
        }
        let converted = preview.previewLayer.captureDevicePointConverted(fromLayerPoint: CGPoint(x: point.x * preview.bounds.width, y: point.y * preview.bounds.height))
        return CGPoint(x: min(max(converted.x, 0), 1), y: min(max(converted.y, 0), 1))
    }
}

/// The capture session with its photo output. AVFoundation wants a session configured and started off the main thread, so
/// everything here happens on one queue of its own; the session object itself is handed to the preview layer, which may read
/// it from the main thread.
private nonisolated final class RearCamera: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "com.matthewcelia.mybirdjournal.capture")
    /// Set on the queue before `open` answers, and read by the viewfinder after that.
    private(set) var device: AVCaptureDevice?
    /// Which way up a photo is, however the phone is held.
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var waiting: [Int64: CheckedContinuation<Data, any Error>] = [:]
    private var sceneObserver: (any NSObjectProtocol)?
    /// Called, on any thread, when the picture has changed under a held focus. Set once, before the camera opens.
    var sceneChanged: (@Sendable () -> Void)?

    deinit {
        if let sceneObserver { NotificationCenter.default.removeObserver(sceneObserver) }
    }

    /// Configures the session the first time and starts it, and says what the camera can zoom through. Nil when the phone
    /// has no rear camera to give.
    func open() async -> RearCameraFacts? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.configureAndRun() ? self.device.map(Self.facts) : nil) }
        }
    }

    /// The rear camera with the most lenses behind it: one device that changes lens by itself as the zoom passes each lens's
    /// start, so zooming never stops to switch. A phone with one rear lens gives that lens.
    private static func rearCamera() -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera],
            mediaType: .video, position: .back
        ).devices.first
    }

    /// What `camera` says of its zoom. Behind a camera of several lenses, each lens after the first starts at a switch-over
    /// factor; a sensor with four pixels to a photo's one also gives a crop of its middle at full quality (the 2× and the 8×
    /// of an iPhone 17 Pro), which its photo formats list.
    private static func facts(of camera: AVCaptureDevice) -> RearCameraFacts {
        func crops(_ lens: AVCaptureDevice) -> [Double] {
            Set(lens.formats.filter(\.isHighestPhotoQualitySupported).flatMap(\.secondaryNativeResolutionZoomFactors)).map { Double($0) }.sorted()
        }
        let behind = camera.constituentDevices
        let starts = [1] + camera.virtualDeviceSwitchOverVideoZoomFactors.map(\.doubleValue)
        let lenses = behind.isEmpty
            ? [RearCameraFacts.Lens(start: Double(camera.minAvailableVideoZoomFactor), fullQualityCrops: crops(camera))]
            : zip(behind, starts).map { RearCameraFacts.Lens(start: $1, fullQualityCrops: crops($0)) }
        return RearCameraFacts(
            minimum: Double(camera.minAvailableVideoZoomFactor), maximum: Double(camera.maxAvailableVideoZoomFactor),
            lenses: lenses, displayMultiplier: Double(camera.displayVideoZoomFactorMultiplier)
        )
    }

    private func configureAndRun() -> Bool {
        if device == nil {
            guard let camera = Self.rearCamera(), let input = try? AVCaptureDeviceInput(device: camera) else { return false }
            session.beginConfiguration()
            session.sessionPreset = .photo
            // A run is listening through the app's audio session: the camera takes no audio and must not reconfigure it.
            session.automaticallyConfiguresApplicationAudioSession = false
            guard session.canAddInput(input), session.canAddOutput(output) else {
                session.commitConfiguration()
                return false
            }
            session.addInput(input)
            session.addOutput(output)
            session.commitConfiguration()
            device = camera
            rotation = AVCaptureDevice.RotationCoordinator(device: camera, previewLayer: nil)
            sceneObserver = NotificationCenter.default.addObserver(forName: AVCaptureDevice.subjectAreaDidChangeNotification, object: camera, queue: nil) { [weak self] _ in
                self?.sceneChanged?()
            }
        }
        if !session.isRunning { session.startRunning() }
        return session.isRunning
    }

    func close() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    /// Sets the zoom, in the camera's own factor. Smoothly glides there, for a lens button; otherwise it is there at once,
    /// for a pinch, and any glide under way stops.
    func zoom(to factor: Double, smoothly: Bool) {
        configure { camera in
            let factor = min(max(CGFloat(factor), camera.minAvailableVideoZoomFactor), camera.maxAvailableVideoZoomFactor)
            if smoothly {
                // In doublings a second: from 0.5× to 8× in half a second.
                camera.ramp(toVideoZoomFactor: factor, withRate: 8)
            } else {
                camera.videoZoomFactor = factor
            }
        }
    }

    /// Focuses and exposes once at `point`, in the camera's own terms, and holds; with nil, lets the camera choose again,
    /// and keep choosing. While a point is held the camera says when the scene changes (`sceneChanged`).
    func focus(at point: CGPoint?) {
        configure { camera in
            let held = point != nil
            let place = point ?? CGPoint(x: 0.5, y: 0.5)
            if camera.isFocusPointOfInterestSupported { camera.focusPointOfInterest = place }
            if held, camera.isFocusModeSupported(.autoFocus) {
                camera.focusMode = .autoFocus
            } else if camera.isFocusModeSupported(.continuousAutoFocus) {
                camera.focusMode = .continuousAutoFocus
            }
            if camera.isExposurePointOfInterestSupported { camera.exposurePointOfInterest = place }
            if held, camera.isExposureModeSupported(.autoExpose) {
                camera.exposureMode = .autoExpose
            } else if camera.isExposureModeSupported(.continuousAutoExposure) {
                camera.exposureMode = .continuousAutoExposure
            }
            camera.isSubjectAreaChangeMonitoringEnabled = held
        }
    }

    private func configure(_ change: @escaping @Sendable (AVCaptureDevice) -> Void) {
        queue.async {
            guard let camera = self.device, (try? camera.lockForConfiguration()) != nil else { return }
            change(camera)
            camera.unlockForConfiguration()
        }
    }

    func capture(_ settings: AVCapturePhotoSettings) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.session.isRunning else {
                    continuation.resume(throwing: CaptureFailure.notReady)
                    return
                }
                if let angle = self.rotation?.videoRotationAngleForHorizonLevelCapture, let connection = self.output.connection(with: .video),
                   connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
                self.waiting[settings.uniqueID] = continuation
                self.output.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: (any Error)?) {
        let id = photo.resolvedSettings.uniqueID
        let result: Result<Data, any Error>
        if let error {
            result = .failure(error)
        } else if let data = photo.fileDataRepresentation() {
            result = .success(data)
        } else {
            result = .failure(CaptureFailure.noPicture)
        }
        queue.async {
            self.waiting.removeValue(forKey: id)?.resume(with: result)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: (any Error)?) {
        // A capture that ended without a photo: nothing must be left waiting on it.
        let id = resolvedSettings.uniqueID
        queue.async {
            self.waiting.removeValue(forKey: id)?.resume(throwing: error ?? CaptureFailure.noPicture)
        }
    }
}

/// The camera's live picture: a preview layer over the session, the whole frame in view and upright in portrait and landscape.
private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let device: AVCaptureDevice?
    let points: ViewfinderPoints

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        private var rotation: AVCaptureDevice.RotationCoordinator?
        private var observation: NSKeyValueObservation?

        /// Keeps the picture level as the phone turns.
        func follow(_ device: AVCaptureDevice?) {
            guard let device, rotation == nil else { return }
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
            rotation = coordinator
            apply(coordinator.videoRotationAngleForHorizonLevelPreview)
            observation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] coordinator, _ in
                let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                Task { @MainActor in self?.apply(angle) }
            }
        }

        private func apply(_ angle: CGFloat) {
            guard let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(angle) else { return }
            connection.videoRotationAngle = angle
        }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        // What's in the viewfinder is what the photo holds.
        view.previewLayer.videoGravity = .resizeAspect
        view.follow(device)
        points.preview = view
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        view.follow(device)
    }
}
