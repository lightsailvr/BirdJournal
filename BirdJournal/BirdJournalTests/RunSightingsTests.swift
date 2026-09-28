import Album
import Foundation
import Identification
import Pack
import SwiftData
import Testing
@testable import BirdJournal

// Issue #28: the ledger the lens's "Add to my list" and the phone's "Add to journal" share.
@Suite("Run sightings")
@MainActor
struct RunSightingsTests {
    static let finch = Species(index: 0, scientificName: "Haemorhous mexicanus", commonName: "House Finch", taxonomicClass: "Aves")

    static func candidate(score: Float) -> Candidate {
        Candidate(species: finch, score: score, windowsAboveThreshold: 2, firstHeardAt: 0, lastHeardAt: 3, admittedAt: 3)
    }

    @Test("a species added from the glasses and again from the phone is one sighting that keeps its first time and place and takes the newer frame")
    func oneSightingPerSpecies() throws {
        let album = try AlbumSchema.makeContainer(inMemory: true)
        let folder = URL.temporaryDirectory.appending(path: "frames-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let frames = FrameStore(directory: folder)
        let ledger = RunSightings(recorder: SightingRecorder(container: album, frames: frames))
        let first = Date(timeIntervalSince1970: 1_800_000_000)
        let here = Coordinate(latitude: 34, longitude: -118, accuracy: 10)

        let glasses = try ledger.add(Self.candidate(score: 0.5), confirmedAt: first, location: here, frame: Data([1]), source: .glasses)
        let phone = try ledger.add(Self.candidate(score: 0.75), confirmedAt: first.addingTimeInterval(60), location: nil, frame: Data([2]), source: .phone)

        #expect(glasses.wasNew && !phone.wasNew)
        #expect(ledger.entries.count == 1)
        #expect(ledger.entries[0].candidate.score == 0.75)
        let stored = try #require(try album.mainContext.fetch(Sighting.newestFirst()).first)
        #expect(try album.mainContext.fetch(Sighting.newestFirst()).count == 1)
        #expect(stored.confirmedAt == first)
        #expect(stored.location == here)
        #expect(stored.soundConfidence == 0.75)
        #expect(stored.source == .glasses)
        let newerFrame = try #require(stored.frameImagePath)
        #expect(newerFrame != phone.previousFramePath)
        #expect(try Data(contentsOf: frames.url(for: newerFrame)) == Data([2]))

        try ledger.undo(phone)
        #expect(stored.soundConfidence == 0.5)
        #expect(stored.frameImagePath == phone.previousFramePath)
        #expect(try Data(contentsOf: frames.url(for: try #require(stored.frameImagePath))) == Data([1]))
        #expect(!FileManager.default.fileExists(atPath: frames.url(for: newerFrame).path(percentEncoded: false)), "the undone frame is gone")
        #expect(ledger.entries[0].candidate.score == 0.5)

        try ledger.undo(glasses)
        #expect(ledger.entries.isEmpty)
        #expect(try album.mainContext.fetch(Sighting.newestFirst()).isEmpty)

        ledger.reset()
        #expect(!ledger.isAdded(Self.finch))
    }

    @Test("a frame an update replaced stays on disk until the undo window closes, then goes; an undone update keeps it")
    func replacedFramesAreDeletedOnCommit() throws {
        let album = try AlbumSchema.makeContainer(inMemory: true)
        let folder = URL.temporaryDirectory.appending(path: "frames-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let frames = FrameStore(directory: folder)
        let ledger = RunSightings(recorder: SightingRecorder(container: album, frames: frames))
        func exists(_ path: String?) -> Bool { path.map { FileManager.default.fileExists(atPath: frames.url(for: $0).path(percentEncoded: false)) } ?? false }

        let first = try ledger.add(Self.candidate(score: 0.5), confirmedAt: .now, location: nil, frame: Data([1]), source: .glasses)
        let second = try ledger.add(Self.candidate(score: 0.6), confirmedAt: .now, location: nil, frame: Data([2]), source: .glasses)
        let firstFrame = try #require(second.previousFramePath)
        #expect(exists(firstFrame), "still there while the update can be undone")

        ledger.commitReplacedFrames()
        #expect(!exists(firstFrame), "gone once the window closed")
        let stored = try #require(try album.mainContext.fetch(Sighting.newestFirst()).first)
        #expect(exists(stored.frameImagePath), "the current frame stays")

        let third = try ledger.add(Self.candidate(score: 0.7), confirmedAt: .now, location: nil, frame: Data([3]), source: .phone)
        let secondFrame = try #require(third.previousFramePath)
        try ledger.undo(third)
        ledger.commitReplacedFrames()
        #expect(exists(secondFrame), "an undone update's earlier frame is back in use, not deleted")
        #expect(stored.frameImagePath == secondFrame)
        _ = first
    }

    @Test("a sighting names its species from the packs, else from its label, so a removed pack leaves the journal readable")
    func namesFallBack() throws {
        let library = PackLibrary.forApp()
        let known = Sighting(speciesID: "Sayornis nigricans_Black phoebe (label spelling)", confirmedAt: .now, soundConfidence: 0.5, source: .phone)
        let unknown = Sighting(speciesID: "Avis ignota_Unknown Bird", confirmedAt: .now, soundConfidence: 0.5, source: .phone)
        #expect(library.commonName(for: known) == (library.bundled == nil ? "Black phoebe (label spelling)" : "Black Phoebe"))
        #expect(library.commonName(for: unknown) == "Unknown Bird")
    }
}
