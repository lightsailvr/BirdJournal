import Album
import Foundation
import Identification
import SwiftData
import Synchronization
import Testing
@testable import BirdJournal

// Issue #52, ADR-0006: the rarity snapshot is read once, at the add, from the sighting's own place and week; a
// sighting saved before rarity existed gets it once from its saved coordinate and date; a saved snapshot is never
// read again.
@Suite("Sighting recorder rarity")
@MainActor
struct SightingRecorderTests {
    static let finch = RunSightingsTests.finch
    static let losFeliz = Coordinate(latitude: 34.1365, longitude: -118.2942, accuracy: 15)
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    struct Fixture {
        let album: ModelContainer
        let recorder: SightingRecorder
        let prior: ScriptedOccurrence
        let defaults: UserDefaults

        var stored: [Sighting] { (try? album.mainContext.fetch(Sighting.newestFirst())) ?? [] }
    }

    static func makeFixture(_ occurrence: [String: Float] = ["Haemorhous mexicanus": 0.5]) throws -> Fixture {
        let album = try AlbumSchema.makeContainer(inMemory: true)
        let prior = ScriptedOccurrence(occurrence)
        let recorder = SightingRecorder(
            container: album,
            frames: FrameStore(directory: URL.temporaryDirectory.appending(path: "frames-\(UUID().uuidString)", directoryHint: .isDirectory)),
            rarity: RarityReader(occurrenceModel: prior, calibration: .forTests)
        )
        let defaults = UserDefaults(suiteName: "recorder-tests-\(UUID().uuidString)")!
        return Fixture(album: album, recorder: recorder, prior: prior, defaults: defaults)
    }

    @Test("an add with a location saves the reading for its place and week; without one, or for a species the geomodel doesn't know, it saves none")
    func addSavesTheSnapshot() throws {
        let fixture = try Self.makeFixture()
        let ledger = RunSightings(recorder: fixture.recorder)

        try ledger.add(RunSightingsTests.candidate(score: 0.5), confirmedAt: Self.start, location: Self.losFeliz, frame: nil, source: .phone)
        let week = GeoContext.week(of: Self.start)
        #expect(fixture.stored.first?.rarity == RaritySnapshot(occurrence: 0.5, label: .uncommon, calibrationVersion: 7, week: week))
        #expect(fixture.prior.asked == [GeoContext(latitude: 34.1365, longitude: -118.2942, week: week)])

        try ledger.add(RunSightingsTests.candidate(score: 0.5), confirmedAt: Self.start.addingTimeInterval(60), location: nil, frame: nil, source: .phone)
        #expect(fixture.stored.first?.rarity == nil, "no location, no snapshot")
        #expect(fixture.prior.asked.count == 1, "nothing is read without a place")

        let unknown = try Self.makeFixture([:])
        try RunSightings(recorder: unknown.recorder).add(RunSightingsTests.candidate(score: 0.5), confirmedAt: Self.start, location: Self.losFeliz, frame: nil, source: .phone)
        #expect(unknown.stored.first?.rarity == nil)
    }

    @Test("sightings from before rarity are backfilled once from their saved coordinate and date; saved snapshots are never read again")
    func backfillOnce() async throws {
        let fixture = try Self.makeFixture()
        let context = fixture.album.mainContext
        let imported = Sighting(speciesID: Self.finch.birdnetLabel, confirmedAt: Self.start, location: Self.losFeliz, soundConfidence: 0.5, source: .glasses)
        let saved = RaritySnapshot(occurrence: 0.9, label: .common, calibrationVersion: 1, week: 3)
        let alreadyRead = Sighting(speciesID: Self.finch.birdnetLabel, confirmedAt: Self.start.addingTimeInterval(60), location: Self.losFeliz, soundConfidence: 0.5, source: .phone)
        alreadyRead.rarity = saved
        let nowhere = Sighting(speciesID: Self.finch.birdnetLabel, confirmedAt: Self.start.addingTimeInterval(120), soundConfidence: 0.5, source: .phone)
        for sighting in [imported, alreadyRead, nowhere] { context.insert(sighting) }
        try context.save()

        await fixture.recorder.backfillRarity(defaults: fixture.defaults)

        let week = GeoContext.week(of: Self.start)
        #expect(imported.rarity == RaritySnapshot(occurrence: 0.5, label: .uncommon, calibrationVersion: 7, week: week))
        #expect(alreadyRead.rarity == saved, "a saved snapshot is never recomputed")
        #expect(nowhere.rarity == nil)
        #expect(fixture.prior.asked == [GeoContext(latitude: 34.1365, longitude: -118.2942, week: week)])
        let identifier = imported.identifier
        let persisted = try ModelContext(fixture.album).fetch(FetchDescriptor<Sighting>(predicate: #Predicate { $0.identifier == identifier })).first
        #expect(persisted?.rarity == imported.rarity, "the backfill is saved")

        // Once only: a later launch reads nothing, even for a located sighting without a snapshot.
        let later = Sighting(speciesID: Self.finch.birdnetLabel, confirmedAt: Self.start, location: Self.losFeliz, soundConfidence: 0.5, source: .phone)
        context.insert(later)
        try context.save()
        await fixture.recorder.backfillRarity(defaults: fixture.defaults)
        #expect(later.rarity == nil)
        #expect(fixture.prior.asked.count == 1)
    }

    @Test("a backfill whose geomodel can't be read saves nothing and stays due, so the next launch fills it")
    func backfillRetriedAfterAFailure() async throws {
        let album = try AlbumSchema.makeContainer(inMemory: true)
        let frames = FrameStore(directory: URL.temporaryDirectory.appending(path: "frames-\(UUID().uuidString)", directoryHint: .isDirectory))
        let defaults = UserDefaults(suiteName: "recorder-tests-\(UUID().uuidString)")!
        let imported = Sighting(speciesID: Self.finch.birdnetLabel, confirmedAt: Self.start, location: Self.losFeliz, soundConfidence: 0.5, source: .glasses)
        album.mainContext.insert(imported)
        try album.mainContext.save()

        let broken = SightingRecorder(container: album, frames: frames, rarity: RarityReader(occurrenceModel: FailingOccurrence(), calibration: .forTests))
        await broken.backfillRarity(defaults: defaults)
        #expect(imported.rarity == nil)
        #expect(!defaults.bool(forKey: SightingRecorder.rarityBackfilledKey))

        let working = SightingRecorder(container: album, frames: frames, rarity: RarityReader(occurrenceModel: ScriptedOccurrence(["Haemorhous mexicanus": 0.5]), calibration: .forTests))
        await working.backfillRarity(defaults: defaults)
        #expect(imported.rarity?.label == .uncommon)
        #expect(defaults.bool(forKey: SightingRecorder.rarityBackfilledKey))
    }
}

/// A geo prior that can't be read, as when the model file is missing.
nonisolated final class FailingOccurrence: SpeciesOccurrenceModel {
    struct Unreadable: Error {}

    func occurrence(in context: GeoContext) throws -> [String: Float] {
        throw Unreadable()
    }
}

/// A geo prior with fixed answers, recording where it was asked.
nonisolated final class ScriptedOccurrence: SpeciesOccurrenceModel {
    private let occurrence: [String: Float]
    private let log = Mutex<[GeoContext]>([])

    init(_ occurrence: [String: Float]) {
        self.occurrence = occurrence
    }

    var asked: [GeoContext] { log.withLock { $0 } }

    func occurrence(in context: GeoContext) throws -> [String: Float] {
        log.withLock { $0.append(context) }
        return occurrence
    }
}

extension RarityCalibration {
    /// Round thresholds under a version no shipped calibration has.
    static let forTests = RarityCalibration(version: 7, floor: 0.03, thresholds: .init(rare: 0.1, uncommon: 0.4, common: 0.75))
}
