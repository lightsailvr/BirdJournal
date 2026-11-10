import AVFoundation
import Observation
import OSLog
import SwiftUI

/// The phone's rear camera on its default lens (issue #186): asks for the camera the first time, shows what it sees and takes
/// a photo with the flash off. It adds no audio input and leaves the app's audio session alone, so a phone-microphone run
/// goes on listening behind it.
///
/// Not exercised by any test: the simulator has no camera. `StandInCaptureCamera` stands in there, and this is checked on an
/// iPhone.
@Observable
final class PhoneCaptureCamera: CaptureCamera {
    private(set) var state = CaptureCameraState.starting
    @ObservationIgnored private let camera = RearCamera()
    private static let logger = Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "capture")

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
        state = await camera.open() ? .ready : .unavailable
        if state == .unavailable { Self.logger.error("the rear camera did not open") }
    }

    func stop() {
        camera.close()
        if state == .ready { state = .starting }
    }

    func takePhoto() async throws -> CapturedPhoto {
        guard state == .ready else { throw CaptureFailure.notReady }
        let data = try await camera.capture()
        return CapturedPhoto(data: data, takenAt: .now)
    }

    var viewfinder: AnyView {
        AnyView(CameraPreview(session: camera.session, device: camera.device).accessibilityHidden(true))
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

    /// Configures the session the first time and starts it. False when the phone has no rear camera to give.
    func open() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.configureAndRun()) }
        }
    }

    private func configureAndRun() -> Bool {
        if device == nil {
            // The rear camera on its default lens, the wide one. #187 adds the other lenses and zoom.
            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: camera) else { return false }
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
        }
        if !session.isRunning { session.startRunning() }
        return session.isRunning
    }

    func close() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func capture() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.session.isRunning else {
                    continuation.resume(throwing: CaptureFailure.notReady)
                    return
                }
                let settings = AVCapturePhotoSettings()
                // Never: it startles the bird and reaches nothing at that distance.
                settings.flashMode = .off
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
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        view.follow(device)
    }
}
