import Album
import Foundation
import Identification
import ImageIO
import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import BirdJournal

// Issue #192 (of #185): the library button and the copy to Photos, on the screens as VoiceOver finds them and presses them.
// The system picker runs outside the app and a test can't choose in it, so a picture is handed over in its place
// (`standInLibraryPhoto`); the Photos library is a stand-in too, which remembers what it was asked and what was added.
@Suite("Library and copy on the camera", .serialized)
@MainActor
struct LibraryCaptureScreenTests {
    typealias Screens = ScreenAccessibilityTests
    typealias Controls = CameraControlsTests

    /// A picture from the library with a date and a place of its own: a spring morning in Griffith Park.
    static func griffithPicture() -> Data {
        LibraryPhotoTests.picture(
            exif: [kCGImagePropertyExifDateTimeOriginal: "2026:04:18 06:42:10", kCGImagePropertyExifOffsetTimeOriginal: "-07:00"],
            gps: [
                kCGImagePropertyGPSLatitude: 34.1365, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 118.2942, kCGImagePropertyGPSLongitudeRef: "W",
            ]
        )
    }

    /// `screen` in a phone-sized window with app accessibility on, the harness's shared objects, a stand-in Photos library and
    /// a stand-in for the library's picker, for as long as `body` runs. `elements` walks what VoiceOver reaches then.
    /// - Parameter geomodel: what "Name this bird" reads its likely birds from (#189): nothing is likely anywhere, unless
    ///   a test says what is.
    static func onScreen(
        _ screen: some View, harness: Screens.Harness, photos: StandInPhotosLibrary, libraryPhoto: Data?, typeSize: DynamicTypeSize = .large,
        geomodel: ScriptedOccurrence = ScriptedOccurrence([:]),
        _ body: (_ elements: () -> [NSObject]) async throws -> Void
    ) async throws {
        await harness.place.prepareForLaunch()
        CardFlipAccessibilityTests.enableAccessibility()
        let hosted = harness.shared(screen, typeSize: typeSize)
            .environment(\.photosCopies, PhotosCopies(library: photos))
            .environment(\.standInLibraryPhoto, libraryPhoto)
            .environment(\.makeCaptureCamera) { StandInCaptureCamera(.ready) }
            .environment(\.occurrenceModel, geomodel)
        let host = UIHostingController(rootView: hosted)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        defer { window.isHidden = true }
        try await body { Controls.elements(host.view) }
    }

    static func captures(_ harness: Screens.Harness) -> [Capture] {
        (try? harness.album.mainContext.fetch(Capture.newestFirst())) ?? []
    }

    @Test("The library is beside the shutter and read before it, on a camera that is open and on one that was refused", arguments: Screens.sizes)
    func theButton(typeSize: DynamicTypeSize) async throws {
        let harness = try Screens.Harness()
        let photos = StandInPhotosLibrary(access: .allowed)

        try await Self.onScreen(CaptureCameraView(camera: StandInCaptureCamera(.ready), taken: { _ in }, close: {}), harness: harness, photos: photos, libraryPhoto: Self.griffithPicture(), typeSize: typeSize) { elements in
            let found = try await Controls.settled(elements) { Controls.element("Choose from library", in: $0) != nil && Controls.element("Viewfinder", in: $0) != nil }
            let labels = Controls.labels(found)
            Screens.expectClean(labels, screen: "Camera with the library")
            let viewfinder = try #require(labels.firstIndex(of: "Viewfinder"), "\(labels)")
            let library = try #require(labels.firstIndex(of: "Choose from library"), "\(labels)")
            let shutter = try #require(labels.firstIndex(of: "Take photo"), "\(labels)")
            #expect(viewfinder < library && library < shutter, "left of the shutter, read first: \(labels)")
            let button = found[library]
            #expect(button.accessibilityTraits.contains(.button))
            #expect(!button.accessibilityTraits.contains(.notEnabled))
            #expect(button.accessibilityHint == "Then you name the bird")
            let frame = button.accessibilityFrame
            let shutterFrame = found[shutter].accessibilityFrame
            #expect(frame.width > 43.9 && frame.height > 43.9, "a finger's size: \(frame)")
            #expect(frame.maxX <= shutterFrame.minX, "\(frame) beside \(shutterFrame)")
            #expect(abs(shutterFrame.midX - 201) < 1, "the shutter stays in the middle: \(shutterFrame)")
        }

        // No camera is no reason not to name a photo there already is.
        try await Self.onScreen(CaptureCameraView(camera: StandInCaptureCamera(.denied), taken: { _ in }, close: {}), harness: harness, photos: photos, libraryPhoto: Self.griffithPicture(), typeSize: typeSize) { elements in
            let found = try await Controls.settled(elements) { Controls.element("Choose from library", in: $0) != nil && Controls.element("Open Settings", in: $0) != nil }
            let library = try #require(Controls.element("Choose from library", in: found), "\(Controls.labels(found))")
            #expect(!library.accessibilityTraits.contains(.notEnabled))
            #expect(Controls.element("Take photo", in: found)?.accessibilityTraits.contains(.notEnabled) == true)
        }
    }

    @Test("The shutter's photo goes to its naming and a copy of it, as it came, to Photos")
    func theShutterKeepsACopy() async throws {
        let harness = try Screens.Harness(seeded: false)
        let photos = StandInPhotosLibrary(access: .notAsked, answer: .allowed)

        try await Self.onScreen(CaptureSightingView(), harness: harness, photos: photos, libraryPhoto: nil) { elements in
            let found = try await Controls.settled(elements) { Controls.element("Take photo", in: $0)?.accessibilityTraits.contains(.notEnabled) == false }
            let shutter = try #require(Controls.element("Take photo", in: found), "\(Controls.labels(found))")
            #expect(shutter.accessibilityActivate())

            let naming = try await Controls.settled(elements) { Controls.labels($0).contains("Name it later") && !photos.added.isEmpty }
            #expect(Controls.labels(naming).contains("Name it later"), "the naming is up: \(Controls.labels(naming))")
            #expect(!Controls.labels(naming).contains { $0.hasPrefix("The sighting takes") || $0.hasPrefix("This photo carries") }, "nothing to say of the camera's own photo: \(Controls.labels(naming))")
            let capture = try #require(Self.captures(harness).first)
            #expect(Self.captures(harness).count == 1)
            #expect(photos.timesAsked == 1, "the first photo asks")
            #expect(photos.added == [try Data(contentsOf: harness.frames.url(for: capture.photoPath))], "the photo the album kept, byte for byte")
        }
    }

    @Test("A no to Photos holds nothing up: the photo is kept in the app and goes to its naming, and the next is not asked about")
    func refusedPhotos() async throws {
        let harness = try Screens.Harness(seeded: false)
        let photos = StandInPhotosLibrary(access: .notAsked, answer: .refused)
        var taken: [CapturedPhoto] = []

        try await Self.onScreen(CaptureCameraView(camera: StandInCaptureCamera(.ready), taken: { taken.append($0) }, close: {}), harness: harness, photos: photos, libraryPhoto: nil) { elements in
            let found = try await Controls.settled(elements) { Controls.element("Take photo", in: $0)?.accessibilityTraits.contains(.notEnabled) == false }
            let shutter = try #require(Controls.element("Take photo", in: found), "\(Controls.labels(found))")
            #expect(shutter.accessibilityActivate())
            _ = try await Controls.settled(elements) { _ in taken.count == 1 && photos.timesAsked == 1 }
            #expect(taken.count == 1)
            #expect(photos.timesAsked == 1)

            let again = try await Controls.settled(elements) { Controls.element("Take photo", in: $0)?.accessibilityTraits.contains(.notEnabled) == false }
            #expect(try #require(Controls.element("Take photo", in: again)).accessibilityActivate())
            _ = try await Controls.settled(elements) { _ in taken.count == 2 }
            try await Task.sleep(for: .milliseconds(300))
            #expect(taken.count == 2)
            #expect(photos.timesAsked == 1, "asked once, ever")
            #expect(photos.added.isEmpty)
            #expect(!Controls.labels(elements()).contains { $0.contains("didn't take") || $0.contains("couldn't") }, "nothing is said of it: \(Controls.labels(elements()))")
        }
    }

    @Test("A photo chosen from the library is written as it came with its own date and place, its naming says so, and nothing is copied back to Photos")
    func chosenFromTheLibrary() async throws {
        // A phone with no run and so no place of its own: every place below is the picture's.
        let harness = try Screens.Harness(seeded: false)
        let photos = StandInPhotosLibrary(access: .notAsked, answer: .allowed)
        let picture = Self.griffithPicture()
        // Where and when the photo was taken, an Allen's Hummingbird is likely.
        let geomodel = ScriptedOccurrence(["Selasphorus sasin": 0.75])
        let taken = try Date("2026-04-18T13:42:10Z", strategy: .iso8601)

        try await Self.onScreen(CaptureSightingView(), harness: harness, photos: photos, libraryPhoto: picture, geomodel: geomodel) { elements in
            let found = try await Controls.settled(elements) { Controls.element("Choose from library", in: $0) != nil }
            let library = try #require(Controls.element("Choose from library", in: found), "\(Controls.labels(found))")
            #expect(library.accessibilityActivate())

            let naming = try await Controls.settled(elements) { labels in
                Controls.labels(labels).contains("The sighting takes this photo's own date and place.") && Controls.labels(labels).contains { $0.hasPrefix("Allen's Hummingbird, ") }
            }
            let labels = Controls.labels(naming)
            Screens.expectClean(labels, screen: "Name this bird, from the library")
            #expect(labels.contains("The sighting takes this photo's own date and place."), "\(labels)")
            let header = try #require(labels.first { $0.hasPrefix("Your photo, ") }, "\(labels)")
            #expect(header.hasPrefix("Your photo, Apr 18, 2026"), "the photo's date, not today's: \(header)")
            #expect(header.contains(", Near "), "the photo's place: \(header)")
            #expect(labels.contains("Allen's Hummingbird, Los Angeles, New to you here"), "placed where the photo was taken: \(labels)")
            // What is suggested is what is likely where and when the photo was taken, not here and now (#189).
            #expect(labels.contains("Likely here now"), "\(labels)")
            let asked = try #require(geomodel.asked.first, "the geomodel was not read")
            #expect((asked.latitude * 10_000).rounded() == 341_365 && (asked.longitude * 10_000).rounded() == -1_182_942, "\(asked)")
            #expect(asked.week == GeoContext.week(of: taken), "\(asked)")

            let capture = try #require(Self.captures(harness).first)
            #expect(Self.captures(harness).count == 1)
            #expect(capture.takenAt == taken)
            #expect(capture.location.map { ($0.latitude * 10_000).rounded() } == 341_365)
            #expect(capture.location.map { ($0.longitude * 10_000).rounded() } == -1_182_942)
            #expect(try Data(contentsOf: harness.frames.url(for: capture.photoPath)) == picture, "not a byte changed")

            try await Task.sleep(for: .milliseconds(300))
            #expect(photos.timesAsked == 0, "it is in the library already")
            #expect(photos.added.isEmpty)
        }
    }

    @Test("A library file that is no picture is said to be unreadable, and the camera stays for another")
    func anUnreadableFile() async throws {
        let harness = try Screens.Harness(seeded: false)
        var taken: [CapturedPhoto] = []

        try await Self.onScreen(CaptureCameraView(camera: StandInCaptureCamera(.ready), taken: { taken.append($0) }, close: {}), harness: harness, photos: StandInPhotosLibrary(access: .allowed), libraryPhoto: Data([1, 2, 3])) { elements in
            let found = try await Controls.settled(elements) { Controls.element("Choose from library", in: $0) != nil }
            #expect(try #require(Controls.element("Choose from library", in: found)).accessibilityActivate())
            let after = try await Controls.settled(elements) { Controls.element("That photo couldn't be read. Try another.", in: $0) != nil }
            #expect(Controls.labels(after).contains("That photo couldn't be read. Try another."), "\(Controls.labels(after))")
            #expect(taken.isEmpty)
            #expect(Controls.element("Choose from library", in: after)?.accessibilityTraits.contains(.notEnabled) == false, "ready for another")
        }
    }
}
