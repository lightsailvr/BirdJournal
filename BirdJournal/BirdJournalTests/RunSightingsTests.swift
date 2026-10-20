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

    @Test("a species added from the glasses and again from the phone is two sightings, each with its own time, place and frame; undo removes one at a time")
    func everyAddIsASighting() throws {
        let album = try AlbumSchema.makeContainer(inMemory: true)
        let folder = URL.temporaryDirectory.appending(path: "frames-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let frames = FrameStore(directory: folder)
        let ledger = RunSightings(recorder: SightingRecorder(container: album, frames: frames))
        let first = Date(timeIntervalSince1970: 1_800_000_000)
        let here = Coordinate(latitude: 34, longitude: -118, accuracy: 10)

        let glasses = try ledger.add(Self.candidate(score: 0.5), confirmedAt: first, location: here, frame: Data([1]), source: .glasses)
        let phone = try ledger.add(Self.candidate(score: 0.75), confirmedAt: first.addingTimeInterval(60), location: nil, frame: Data([2]), source: .phone)

        #expect(glasses.sightingID != phone.sightingID)
        #expect(ledger.entries.map(\.candidate.score) == [0.5, 0.75])
        #expect(ledger.count(of: Self.finch) == 2)
        let stored = try album.mainContext.fetch(Sighting.newestFirst())
        #expect(stored.count == 2)
        #expect(stored.map(\.confirmedAt) == [first.addingTimeInterval(60), first])
        #expect(stored.map(\.location) == [nil, here])
        #expect(stored.map(\.source) == [.phone, .glasses])
        let paths = stored.compactMap(\.frameImagePath)
        #expect(try paths.map { try Data(contentsOf: frames.url(for: $0)) } == [Data([2]), Data([1])])

        try ledger.undo(phone)
        #expect(ledger.count(of: Self.finch) == 1)
        #expect(try album.mainContext.fetch(Sighting.newestFirst()).map(\.source) == [.glasses])
        #expect(!FileManager.default.fileExists(atPath: frames.url(for: paths[0]).path(percentEncoded: false)), "the undone frame is gone")
        #expect(FileManager.default.fileExists(atPath: frames.url(for: paths[1]).path(percentEncoded: false)))

        try ledger.undo(glasses)
        try ledger.undo(glasses)
        #expect(ledger.entries.isEmpty)
        #expect(try album.mainContext.fetch(Sighting.newestFirst()).isEmpty)

        ledger.reset()
        #expect(!ledger.isAdded(Self.finch))
    }

    @Test("an add writes a card: its own identifier and Heard, and a Legendary only when no other surviving sighting of the species exists (issue #51)")
    func addEarnsACard() throws {
        let album = try AlbumSchema.makeContainer(inMemory: true)
        let folder = URL.temporaryDirectory.appending(path: "frames-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let ledger = RunSightings(recorder: SightingRecorder(container: album, frames: FrameStore(directory: folder)))
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func stored() throws -> [Sighting] { try album.mainContext.fetch(Sighting.newestFirst()) }

        let first = try ledger.add(Self.candidate(score: 0.5), confirmedAt: start, location: nil, frame: nil, source: .glasses)
        #expect(first.isLegendary)
        let written = try #require(try stored().first)
        #expect(written.identifier == first.identifier)
        #expect(written.method == .heard)

        let second = try ledger.add(Self.candidate(score: 0.6), confirmedAt: start.addingTimeInterval(60), location: nil, frame: nil, source: .phone)
        #expect(!second.isLegendary, "a repeat add is a new card")
        #expect(second.identifier != first.identifier)
        #expect(Set(try stored().map(\.identifier)) == [first.identifier, second.identifier])

        // With the first gone, the second survives: another add is still not the birder's first.
        try ledger.undo(first)
        #expect(!(try ledger.add(Self.candidate(score: 0.7), confirmedAt: start.addingTimeInterval(120), location: nil, frame: nil, source: .phone).isLegendary))

        // Once no sighting of the species survives, the next add is Legendary again.
        for sighting in try stored() { album.mainContext.delete(sighting) }
        try album.mainContext.save()
        #expect(try ledger.add(Self.candidate(score: 0.8), confirmedAt: start.addingTimeInterval(180), location: nil, frame: nil, source: .phone).isLegendary)

        // A sighting from an earlier run counts as surviving too.
        let otherAlbum = try AlbumSchema.makeContainer(inMemory: true)
        otherAlbum.mainContext.insert(Sighting(speciesID: Self.finch.birdnetLabel, confirmedAt: start.addingTimeInterval(-86_400), soundConfidence: 0.5, source: .glasses))
        try otherAlbum.mainContext.save()
        let nextRun = RunSightings(recorder: SightingRecorder(container: otherAlbum, frames: FrameStore(directory: folder)))
        #expect(!(try nextRun.add(Self.candidate(score: 0.9), confirmedAt: start, location: nil, frame: nil, source: .phone).isLegendary))
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
