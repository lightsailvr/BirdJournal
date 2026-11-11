import Album
import CoreImage
import Foundation
import ImageIO
import SwiftData
import Testing
import UniformTypeIdentifiers
@testable import BirdJournal

// Issue #28: notes on a sighting, and a removal that can be undone while its window is open.
@Suite("Journal edits")
@MainActor
struct JournalEditsTests {
    @Test("a note is saved and trimmed, an empty note clears it")
    func notes() throws {
        let album = try AlbumSchema.makeContainer(inMemory: true)
        let edits = JournalEdits(container: album, frames: FrameStore(directory: URL.temporaryDirectory))
        let sighting = Sighting(speciesID: "Sayornis nigricans_Black Phoebe", confirmedAt: .now, soundConfidence: 0.8, source: .glasses)
        album.mainContext.insert(sighting)
        try album.mainContext.save()

        edits.setNote("  Tail dipping.  \n", on: sighting)
        #expect(try album.mainContext.fetch(Sighting.newestFirst()).first?.note == "Tail dipping.")
        edits.setNote("   ", on: sighting)
        #expect(try album.mainContext.fetch(Sighting.newestFirst()).first?.note == nil)
    }

    @Test("a sighting is Heard until the birder says Seen on the card's back; the change persists and can go back (issue #52)")
    func method() throws {
        let album = try AlbumSchema.makeContainer(inMemory: true)
        let edits = JournalEdits(container: album, frames: FrameStore(directory: URL.temporaryDirectory))
        let sighting = Sighting(speciesID: "Sayornis nigricans_Black Phoebe", confirmedAt: .now, soundConfidence: 0.8, source: .glasses)
        album.mainContext.insert(sighting)
        try album.mainContext.save()
        func persisted() throws -> SightingMethod? { try ModelContext(album).fetch(Sighting.newestFirst()).first?.method }
        #expect(try persisted() == .heard)

        edits.setMethod(.seen, on: sighting)
        #expect(try persisted() == .seen)
        edits.setMethod(.heard, on: sighting)
        #expect(try persisted() == .heard)
    }

    @Test("a removed sighting is gone from the album, comes back whole on undo, and its frame outlives the window only until it closes")
    func removeAndUndo() throws {
        let album = try AlbumSchema.makeContainer(inMemory: true)
        let folder = URL.temporaryDirectory.appending(path: "frames-\(UUID().uuidString)", directoryHint: .isDirectory)
        let frames = FrameStore(directory: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let edits = JournalEdits(container: album, frames: frames)
        let path = try frames.write(jpeg: Data([0xFF, 0xD8, 0xFF]))
        let coordinate = Coordinate(latitude: 34.1, longitude: -118.3, accuracy: 10)
        let attached = try frames.write(jpeg: Data([0xFF, 0xD8, 0xFE]))
        let sighting = Sighting(speciesID: "Sayornis nigricans_Black Phoebe", confirmedAt: Date(timeIntervalSince1970: 1_800_000_000), location: coordinate, soundConfidence: 0.8, frameImagePath: path, source: .glasses, note: "Over the pond", method: .seen)
        sighting.rarity = RaritySnapshot(occurrence: 0.2, label: .rare, calibrationVersion: 1, week: 40)
        sighting.caption = CardCaption(text: "The pond's dark keeper.", generatorVersion: "fm-1")
        sighting.art = CardArt(prefersPackArt: true)
        sighting.attachedPhotoPaths = [attached]
        let identifier = sighting.identifier
        album.mainContext.insert(sighting)
        try album.mainContext.save()

        edits.remove(sighting, commonName: "Black Phoebe")

        #expect(try album.mainContext.fetch(Sighting.newestFirst()).isEmpty)
        #expect(edits.pendingRemoval?.commonName == "Black Phoebe")
        #expect(FileManager.default.fileExists(atPath: frames.url(for: path).path(percentEncoded: false)), "the frame waits for the undo window")

        edits.undoRemoval()

        let restored = try #require(try album.mainContext.fetch(Sighting.newestFirst()).first)
        #expect(restored.speciesID == "Sayornis nigricans_Black Phoebe")
        #expect(restored.confirmedAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(restored.location == coordinate)
        #expect(restored.frameImagePath == path)
        #expect(restored.note == "Over the pond")
        #expect(restored.identifier == identifier, "the same card comes back, not a new one")
        #expect(restored.method == .seen)
        #expect(restored.rarity?.label == .rare)
        #expect(restored.caption?.text == "The pond's dark keeper.")
        #expect(restored.art.prefersPackArt)
        #expect(restored.attachedPhotoPaths == [attached])
        #expect(edits.pendingRemoval == nil)

        edits.remove(restored, commonName: "Black Phoebe")
        edits.commitPendingRemoval()
        #expect(edits.pendingRemoval == nil)
        #expect(!FileManager.default.fileExists(atPath: frames.url(for: path).path(percentEncoded: false)), "the frame goes once the removal stands")
        #expect(!FileManager.default.fileExists(atPath: frames.url(for: attached).path(percentEncoded: false)), "and the attached photo with it")
    }

    @Test("a removed sighting the birder named comes back named by the birder: no match score, no Heard to choose (issue #186)")
    func undoKeepsNamedByBirder() throws {
        let album = try AlbumSchema.makeContainer(inMemory: true)
        let edits = JournalEdits(container: album, frames: FrameStore(directory: URL.temporaryDirectory))
        let sighting = Sighting(speciesID: "Selasphorus sasin_Allen's Hummingbird", confirmedAt: .now, soundConfidence: 0, source: .phone, method: .seen, namedByBirder: true)
        sighting.attachedPhotoPaths = ["capture.jpeg"]
        album.mainContext.insert(sighting)
        try album.mainContext.save()

        edits.remove(sighting, commonName: "Allen's Hummingbird")
        edits.undoRemoval()

        let restored = try #require(try album.mainContext.fetch(Sighting.newestFirst()).first)
        #expect(restored.namedByBirder, "still a bird the birder named")
        #expect(CardText.matchScore(restored) == nil, "so it shows no match score")
        #expect(CardText.how(restored) == "Seen, photographed with iPhone")
    }

    private func harness() throws -> (edits: JournalEdits, frames: FrameStore, sighting: Sighting, album: ModelContainer) {
        let album = try AlbumSchema.makeContainer(inMemory: true)
        let frames = FrameStore(directory: URL.temporaryDirectory.appending(path: "frames-\(UUID().uuidString)", directoryHint: .isDirectory))
        let sighting = Sighting(speciesID: "Zenaida macroura_Mourning Dove", confirmedAt: .now, soundConfidence: 0.7, source: .phone)
        album.mainContext.insert(sighting)
        try album.mainContext.save()
        return (JournalEdits(container: album, frames: frames), frames, sighting, album)
    }

    /// A picture as the library hands it over, in a format that isn't the store's JPEG.
    private func png() throws -> Data {
        let rendered = try #require(CIContext().createCGImage(CIImage(color: .green).cropped(to: CGRect(x: 0, y: 0, width: 40, height: 30)), from: CGRect(x: 0, y: 0, width: 40, height: 30)))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, rendered, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    @Test("an attached photo is kept on the sighting as it came, changes nothing else, and is what a share sends")
    func attachPhoto() throws {
        let (edits, frames, sighting, album) = try harness()
        defer { try? FileManager.default.removeItem(at: frames.directory) }
        let photo = try png()

        try edits.attachPhoto(photo, to: sighting)

        let reopened = try #require(try album.mainContext.fetch(Sighting.newestFirst()).first)
        let path = try #require(reopened.attachedPhotoPaths.first)
        #expect(reopened.attachedPhotoPaths == [path])
        #expect(path.hasSuffix(".png"), "kept in the format it came in")
        #expect(try Data(contentsOf: frames.url(for: path)) == photo, "the original, unaltered")
        #expect(reopened.method == .heard, "attaching a photo doesn't say the bird was seen")
        #expect(reopened.artState == nil, "no painting is asked for")
        #expect(CardText.originalPhotoPath(reopened) == path)
        #expect(CardText.evidence(reopened) == "Photo attached")
        #expect(reopened.filePaths.contains(path), "it goes with the sighting")
        // The share's original photo reads this file; what leaves is the prepared JPEG.
        let prepared = try SharedPhoto.prepare(jpeg: Data(contentsOf: frames.url(for: path)))
        #expect(prepared.jpeg.starts(with: [0xFF, 0xD8]))
    }

    @Test("what isn't a picture is refused, and nothing is kept")
    func attachRefusesNonPicture() throws {
        let (edits, frames, sighting, _) = try harness()
        defer { try? FileManager.default.removeItem(at: frames.directory) }
        #expect(throws: JournalEdits.AttachFailure.unreadable) { try edits.attachPhoto(Data("not a picture".utf8), to: sighting) }
        #expect(sighting.attachedPhotoPaths.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: frames.directory.path(percentEncoded: false)), "nothing written")
    }

    @Test("removing an attached photo takes its file and leaves the glasses photo")
    func removeAttachedPhoto() throws {
        let (edits, frames, sighting, _) = try harness()
        defer { try? FileManager.default.removeItem(at: frames.directory) }
        let frame = try frames.write(jpeg: try png())
        sighting.frameImagePath = frame
        try edits.attachPhoto(try png(), to: sighting)
        let path = try #require(sighting.attachedPhotoPaths.first)

        edits.removeAttachedPhoto(path, from: sighting)

        #expect(sighting.attachedPhotoPaths.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: frames.url(for: path).path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: frames.url(for: frame).path(percentEncoded: false)))
        #expect(CardText.originalPhotoPath(sighting) == frame, "back to the glasses photo")
    }
}
