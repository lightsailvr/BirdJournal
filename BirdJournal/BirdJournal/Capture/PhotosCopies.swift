import Foundation
import OSLog
import Photos
import SwiftUI

/// Whether the app may add photos to the birder's Photos library. Adding is all it ever asks for: it can't read the library.
enum PhotosAddAccess: Equatable, Sendable {
    /// The phone hasn't asked the birder yet.
    case notAsked
    case allowed
    /// The birder said no, or the phone doesn't let them say yes. Only Settings changes it.
    case refused
}

/// The Photos library as the capture camera needs it (issue #192, of #185): somewhere to add a photo, once the birder has
/// said the app may. The phone's own is `SystemPhotosLibrary`; `StandInPhotosLibrary` stands in for the tests and for a
/// launch with a stand-in camera.
@MainActor
protocol PhotosAdding: AnyObject {
    var addAccess: PhotosAddAccess { get }
    /// Has the phone ask the birder, which it does once ever, and gives the answer.
    func askToAdd() async -> PhotosAddAccess
    /// Adds a photo's file to the library as it is.
    func add(_ photo: Data) async throws
}

/// Saves a copy of each photo taken with the capture camera to the birder's Photos library (issue #192, of #185), so the
/// picture is theirs outside the app too. The first photo asks for add-only access. A no is final: it is never raised
/// again, here or anywhere in the app, and the capture goes on to its naming all the same. A photo that was chosen from
/// the library is already there and is not saved back.
@MainActor
final class PhotosCopies {
    private static let logger = Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "capture")

    enum Outcome: Equatable, Sendable {
        case saved
        /// It came from the library: there is nothing to copy.
        case notTheCameras
        /// The birder has said no to adding, now or before.
        case notAllowed
        /// Photos wouldn't take it. The photo itself is with its sighting in the app.
        case failed
    }

    private let library: any PhotosAdding
    /// The question while it is up, so two photos taken behind it are one question.
    private var asking: Task<PhotosAddAccess, Never>?

    init(library: any PhotosAdding) {
        self.library = library
    }

    /// Saves a copy of `photo` if it is the camera's and the birder allows it, asking them the first time. Never throws and
    /// never blocks a capture: the caller hands the photo on to its naming without waiting for this.
    @discardableResult
    func keep(_ photo: CapturedPhoto) async -> Outcome {
        guard photo.origin == .camera else { return .notTheCameras }
        guard await access() == .allowed else { return .notAllowed }
        do {
            try await library.add(photo.data)
            return .saved
        } catch {
            Self.logger.error("copy to Photos failed: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }

    private func access() async -> PhotosAddAccess {
        guard library.addAccess == .notAsked else { return library.addAccess }
        if let asking { return await asking.value }
        let question = Task { await library.askToAdd() }
        asking = question
        let answer = await question.value
        asking = nil
        Self.logger.info("add to Photos: \(answer == .allowed ? "allowed" : "refused", privacy: .public)")
        return answer
    }
}

extension PhotosCopies {
    /// The app's: over the phone's Photos library. In debug builds a launch with a stand-in camera (`-fakeCamera`) gets a
    /// stand-in library too, so a UI test never meets the phone's question and a drawn photo never lands in a real library;
    /// and so does the app when it hosts the unit tests, where a screen under test may press the shutter.
    static let forApp: PhotosCopies = {
        #if DEBUG
        let hostsTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if hostsTests || UserDefaults.standard.string(forKey: "fakeCamera") != nil { return PhotosCopies(library: StandInPhotosLibrary(access: .allowed)) }
        #endif
        return PhotosCopies(library: SystemPhotosLibrary())
    }()
}

extension EnvironmentValues {
    /// Where the capture camera's photos are copied to: the birder's Photos library, unless a test stands one in.
    @Entry var photosCopies: PhotosCopies = .forApp
}

/// The phone's Photos library, with add-only access: the app can put a photo in and can't see what is there.
final class SystemPhotosLibrary: PhotosAdding {
    var addAccess: PhotosAddAccess {
        Self.access(PHPhotoLibrary.authorizationStatus(for: .addOnly))
    }

    func askToAdd() async -> PhotosAddAccess {
        Self.access(await PHPhotoLibrary.requestAuthorization(for: .addOnly))
    }

    func add(_ photo: Data) async throws {
        try await Self.write(photo)
    }

    /// Off the main actor: Photos runs the change on a queue of its own.
    nonisolated private static func write(_ photo: Data) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            // The file as the camera wrote it: Photos reads its date and its orientation from it.
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: photo, options: nil)
        }
    }

    nonisolated static func access(_ status: PHAuthorizationStatus) -> PhotosAddAccess {
        switch status {
        case .notDetermined: .notAsked
        case .authorized, .limited: .allowed
        case .denied, .restricted: .refused
        @unknown default: .refused
        }
    }
}

#if DEBUG
/// A Photos library with no library: it remembers what it was asked and what was added, and answers as told.
final class StandInPhotosLibrary: PhotosAdding {
    private(set) var addAccess: PhotosAddAccess
    /// How many times the birder has been asked.
    private(set) var timesAsked = 0
    /// The photos added, in order.
    private(set) var added: [Data] = []
    private let answer: PhotosAddAccess
    private let fails: Bool

    struct Unwritable: Error {}

    /// - Parameters:
    ///   - access: where the phone stands when the app starts.
    ///   - answer: what the birder says when asked.
    ///   - fails: Photos takes nothing, as with a full phone.
    init(access: PhotosAddAccess, answer: PhotosAddAccess = .allowed, fails: Bool = false) {
        self.addAccess = access
        self.answer = answer
        self.fails = fails
    }

    func askToAdd() async -> PhotosAddAccess {
        timesAsked += 1
        // As the phone's question does, it takes a moment.
        await Task.yield()
        addAccess = answer
        return answer
    }

    func add(_ photo: Data) async throws {
        if fails { throw Unwritable() }
        added.append(photo)
    }
}
#endif
