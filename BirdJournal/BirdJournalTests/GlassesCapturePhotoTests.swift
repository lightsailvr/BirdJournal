import Album
import Foundation
import Identification
import SwiftData
import Testing
import UIKit
@testable import BirdJournal

// The review of #185, c1: the lens's capture viewfinder marks the journal's crop (`FrameCrop.albumZoom`) and the wearer
// frames the bird inside it, so the phone must show that photo at that crop wherever it shows it. A photo taken from the
// lens is the sighting's glasses photo once it is named (`frameImagePath`), as the photo of an add on the lens is, and a
// capture's one photo is a glasses photo when the glasses took it. Photos from the phone's camera and the library stay
// the birder's own, shown whole. No album schema change.
@Suite("A glasses capture's photo at the journal's crop")
@MainActor
struct GlassesCapturePhotoTests {
    typealias Fixture = UnnamedSightingTests.Fixture
    static let allens = SeenSightingTests.allens
    static let finch = SeenSightingTests.finch
    static let losFeliz = SeenSightingTests.losFeliz
    static let taken = SeenSightingTests.taken

    /// A photo taken from the lens and named an Allen's Hummingbird.
    static func namedFromTheLens(_ fixture: Fixture) throws -> (sighting: Sighting, photo: String, addition: RunSightings.Addition) {
        let unnamed = try fixture.ledger.capture(photo: DebugSeeds.frameJPEG(), takenAt: taken, location: losFeliz, source: .glasses)
        let addition = try fixture.ledger.name(unnamed, as: allens)
        let sighting = try #require(fixture.sightings.first { $0.identifier == addition.identifier })
        return (sighting, unnamed.photoPath, addition)
    }

    @Test("naming a photo taken from the lens keeps it as the sighting's glasses photo, so its row and its page show it at the journal's crop; one from the phone's camera stays one of the birder's own, shown whole")
    func namedFromTheLensOrThePhone() throws {
        let fixture = try UnnamedSightingTests.makeFixture()
        let (fromLens, lensPhoto, _) = try Self.namedFromTheLens(fixture)
        let phone = try fixture.ledger.capture(photo: DebugSeeds.frameJPEG(), takenAt: Self.taken.addingTimeInterval(60), location: Self.losFeliz, source: .phone)
        let phoneAddition = try fixture.ledger.name(phone, as: Self.finch)
        let fromPhone = try #require(fixture.sightings.first { $0.identifier == phoneAddition.identifier })

        #expect(fromLens.frameImagePath == lensPhoto, "the glasses' photo of the sighting")
        #expect(fromLens.attachedPhotoPaths.isEmpty)
        #expect(fromLens.namedByBirder && fromLens.method == .seen && fromLens.source == .glasses)
        #expect(RowPictureSource.of(sighting: fromLens, reference: nil) == .ownPhoto(path: lensPhoto, isGlassesFrame: true), "cropped, as the viewfinder marked it")
        #expect(CardText.originalPhotoPath(fromLens) == lensPhoto, "\"View original photo\" opens the whole frame")
        #expect(CardText.how(fromLens) == "Seen, photographed with Ray-Ban Display")
        #expect(Set(fixture.files) == [lensPhoto, phone.photoPath], "the same files, never copied")

        #expect(fromPhone.frameImagePath == nil)
        #expect(fromPhone.attachedPhotoPaths == [phone.photoPath])
        #expect(RowPictureSource.of(sighting: fromPhone, reference: nil) == .ownPhoto(path: phone.photoPath, isGlassesFrame: false), "whole")
    }

    @Test("Undo of the naming leaves the photo waiting as a capture from the glasses, the same file; named again, it is the glasses photo again")
    func undoOfTheNaming() throws {
        let fixture = try UnnamedSightingTests.makeFixture()
        let (_, photo, addition) = try Self.namedFromTheLens(fixture)

        try fixture.ledger.undo(addition)

        #expect(fixture.sightings.isEmpty)
        let waiting = try #require(fixture.ledger.unnamed.first)
        #expect(fixture.ledger.unnamed.count == 1)
        #expect(waiting.photoPath == photo && waiting.source == .glasses, "still the glasses' photo, to show at the crop")
        #expect(waiting.takenAt == Self.taken && waiting.location == Self.losFeliz)
        #expect(fixture.files == [photo], "the photo was kept")

        let again = try fixture.ledger.name(waiting, as: Self.finch)
        let sighting = try #require(fixture.sightings.first { $0.identifier == again.identifier })
        #expect(sighting.frameImagePath == photo && sighting.attachedPhotoPaths.isEmpty)
        #expect(RowPictureSource.of(sighting: sighting, reference: nil) == .ownPhoto(path: photo, isGlassesFrame: true))
    }

    @Test("\"Change bird\" keeps the photo where it is and at its crop")
    func changeBird() throws {
        let fixture = try UnnamedSightingTests.makeFixture()
        let (sighting, photo, _) = try Self.namedFromTheLens(fixture)

        try fixture.ledger.recorder.changeBird(of: sighting, to: Self.finch)

        #expect(sighting.scientificName == "Haemorhous mexicanus")
        #expect(sighting.frameImagePath == photo && sighting.attachedPhotoPaths.isEmpty)
        #expect(RowPictureSource.of(sighting: sighting, reference: nil) == .ownPhoto(path: photo, isGlassesFrame: true))
    }

    @Test("a photo attached from the library to such a sighting leads, whole; \"Remove photo\" takes it off and the glasses photo is back at its crop; a removal and its Undo keep it too")
    func attachRemoveAndRestore() throws {
        let fixture = try UnnamedSightingTests.makeFixture()
        let (sighting, photo, addition) = try Self.namedFromTheLens(fixture)
        let edits = JournalEdits(container: fixture.album, frames: fixture.frames, recorder: fixture.ledger.recorder)

        try edits.attachPhoto(DebugSeeds.frameJPEG(), to: sighting)
        let attached = try #require(sighting.attachedPhotoPaths.first)
        #expect(attached != photo)
        #expect(RowPictureSource.of(sighting: sighting, reference: nil) == .ownPhoto(path: attached, isGlassesFrame: false), "the birder's own photo is never cropped")

        edits.removeAttachedPhoto(attached, from: sighting)
        #expect(RowPictureSource.of(sighting: sighting, reference: nil) == .ownPhoto(path: photo, isGlassesFrame: true))
        #expect(fixture.files == [photo])

        edits.remove(sighting, commonName: "Allen's Hummingbird")
        #expect(fixture.sightings.isEmpty)
        edits.undoRemoval()
        let restored = try #require(fixture.sightings.first)
        #expect(restored.identifier == addition.identifier && restored.namedByBirder)
        #expect(RowPictureSource.of(sighting: restored, reference: nil) == .ownPhoto(path: photo, isGlassesFrame: true))
    }

    @Test("after the app is killed and started again the album still says whose photo each is: the named sighting's, and a capture still waiting")
    func afterARelaunch() throws {
        let folder = URL.temporaryDirectory.appending(path: "glasses-crop-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let frames = FrameStore(directory: folder.appending(path: "Frames", directoryHint: .isDirectory))
        let url = folder.appending(path: "album.store")

        let named: String, waiting: String
        do {
            let fixture = try UnnamedSightingTests.makeFixture(album: AlbumSchema.makeContainer(at: url), frames: frames)
            named = try Self.namedFromTheLens(fixture).photo
            waiting = try fixture.ledger.capture(photo: DebugSeeds.frameJPEG(), takenAt: Self.taken.addingTimeInterval(60), location: nil, source: .glasses).photoPath
        }

        // One container per file at a time: the next launch opens the store after the first has gone.
        let relaunched = try UnnamedSightingTests.makeFixture(album: AlbumSchema.makeContainer(at: url), frames: frames)
        let sighting = try #require(relaunched.sightings.first)
        #expect(RowPictureSource.of(sighting: sighting, reference: nil) == .ownPhoto(path: named, isGlassesFrame: true))
        let capture = try #require(relaunched.captures.first)
        #expect(capture.photoPath == waiting && capture.source == .glasses)
        #expect(UnnamedSighting(capture).isGlassesFrame)

        // The run's rows, read back for a review after the kill, say the same.
        relaunched.ledger.restoreSeen([sighting.identifier])
        relaunched.ledger.restoreUnnamed([capture.identifier])
        #expect(relaunched.ledger.seen.map(\.photoPath) == [named] && relaunched.ledger.seen.map(\.photoIsGlassesFrame) == [true])
        #expect(relaunched.ledger.unnamed.map(\.isGlassesFrame) == [true])
    }

    // MARK: - What the rows and the sheet are told

    @Test("the run's rows, the Collection's \"To name\" and both naming sheets are told which photos are the glasses' own: a capture by the device that took it, a sighting by where its photo is kept")
    func whatTheScreensAreTold() throws {
        let fixture = try UnnamedSightingTests.makeFixture()
        let lens = try fixture.ledger.capture(photo: DebugSeeds.frameJPEG(), takenAt: Self.taken, location: Self.losFeliz, source: .glasses)
        let phone = try fixture.ledger.capture(photo: DebugSeeds.frameJPEG(), takenAt: Self.taken.addingTimeInterval(60), location: Self.losFeliz, source: .phone)

        // Waiting: the rows under "Seen this run" and "To name", and "Name this bird".
        #expect(lens.isGlassesFrame && !phone.isGlassesFrame)
        #expect(NamingSubject.unnamed(lens).photoIsGlassesFrame && !NamingSubject.unnamed(phone).photoIsGlassesFrame)

        // Named: the rows under "Seen this run" (and so the run's review), and "Change bird".
        try fixture.ledger.name(lens, as: Self.allens)
        try fixture.ledger.name(phone, as: Self.finch)
        #expect(fixture.ledger.seen.map(\.photoPath) == [lens.photoPath, phone.photoPath])
        #expect(fixture.ledger.seen.map(\.photoIsGlassesFrame) == [true, false])
        let fromLens = try #require(fixture.sightings.first { $0.source == .glasses })
        let fromPhone = try #require(fixture.sightings.first { $0.source == .phone })
        let changingLens = NamedSighting(fromLens, commonName: "Allen's Hummingbird"), changingPhone = NamedSighting(fromPhone, commonName: "House Finch")
        #expect(changingLens.photoPath == lens.photoPath && changingLens.photoIsGlassesFrame)
        #expect(changingPhone.photoPath == phone.photoPath && !changingPhone.photoIsGlassesFrame)
        #expect(NamingSubject.named(changingLens).photoIsGlassesFrame && !NamingSubject.named(changingPhone).photoIsGlassesFrame)

        // A bird BirdNET heard and the lens added: its frame was always the glasses', and still is.
        let heard = try fixture.ledger.add(RunSightingsTests.candidate(score: 0.8), confirmedAt: Self.taken, location: Self.losFeliz, frame: DebugSeeds.frameJPEG(), source: .glasses)
        let added = try #require(fixture.sightings.first { $0.identifier == heard.identifier })
        #expect(CardText.originalPhotoIsGlassesFrame(added))
        #expect(CardText.glassesSnapshotNote(added).contains("when you added the bird"))
        #expect(CardText.glassesSnapshotNote(fromLens).contains("the photo you took from the lens"))
    }

    // MARK: - The pixels

    /// The stand-in frame has a black border all round and a white ring in the middle: whole, its corner is black; at the
    /// journal's crop the border is cut away and the corner is the green of the field.
    @Test("a glasses photo is drawn as the middle of the frame at the album's zoom, the same shape and at least as many pixels as the slot asks for; another photo is drawn whole")
    func theCropItself() throws {
        let url = URL.temporaryDirectory.appending(path: "crop-\(UUID().uuidString).jpg")
        try DebugSeeds.frameJPEG().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let whole = try #require(BirderPhoto.fitted(at: url, maxPixels: 360))
        let cropped = try #require(BirderPhoto.fitted(at: url, maxPixels: 360, zoom: FrameCrop.albumZoom))

        #expect(Self.brightness(of: whole, at: CGPoint(x: 0.02, y: 0.02)) < 0.2, "the border, at the edge of the whole photo")
        #expect(Self.brightness(of: cropped, at: CGPoint(x: 0.02, y: 0.02)) > 0.3, "no border: the crop starts inside it")
        #expect(Self.brightness(of: cropped, at: CGPoint(x: 0.5, y: 0.43)) > 0.9, "the ring from the middle of the frame, twice the size")
        let wholeSize = whole.cgImage.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
        let croppedSize = cropped.cgImage.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
        #expect(abs(wholeSize.width / wholeSize.height - croppedSize.width / croppedSize.height) < 0.02, "\(wholeSize) and \(croppedSize)")
        #expect(max(croppedSize.width, croppedSize.height) >= 359, "not a quarter of the pixels: \(croppedSize)")
        #expect(FrameCrop.albumZoom == 2, "the crop the lens's viewfinder marks")
    }

    /// The brightness, 0 to 1, of `image` at a point given in fractions of its width and height.
    static func brightness(of image: UIImage, at point: CGPoint) -> Double {
        guard let cgImage = image.cgImage else { return -1 }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return -1 }
        let x = (CGFloat(cgImage.width) * point.x).rounded(.down), y = (CGFloat(cgImage.height) * point.y).rounded(.down)
        // Core Graphics draws from the bottom left: the pixel wanted is moved to the context's one pixel.
        context.draw(cgImage, in: CGRect(x: -x, y: -(CGFloat(cgImage.height) - 1 - y), width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
        return (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / (3 * 255)
    }
}
