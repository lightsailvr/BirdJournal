import Album
import Foundation
import SwiftData
import Testing
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

    @Test("a removed sighting is gone from the album, comes back whole on undo, and its frame outlives the window only until it closes")
    func removeAndUndo() throws {
        let album = try AlbumSchema.makeContainer(inMemory: true)
        let folder = URL.temporaryDirectory.appending(path: "frames-\(UUID().uuidString)", directoryHint: .isDirectory)
        let frames = FrameStore(directory: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let edits = JournalEdits(container: album, frames: frames)
        let path = try frames.write(jpeg: Data([0xFF, 0xD8, 0xFF]))
        let coordinate = Coordinate(latitude: 34.1, longitude: -118.3, accuracy: 10)
        let sighting = Sighting(speciesID: "Sayornis nigricans_Black Phoebe", confirmedAt: Date(timeIntervalSince1970: 1_800_000_000), location: coordinate, soundConfidence: 0.8, frameImagePath: path, source: .glasses, note: "Over the pond")
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
        #expect(edits.pendingRemoval == nil)

        edits.remove(restored, commonName: "Black Phoebe")
        edits.commitPendingRemoval()
        #expect(edits.pendingRemoval == nil)
        #expect(!FileManager.default.fileExists(atPath: frames.url(for: path).path(percentEncoded: false)), "the frame goes once the removal stands")
    }
}
