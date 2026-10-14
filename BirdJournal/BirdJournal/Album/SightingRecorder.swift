import Album
import Foundation
import Identification
import OSLog
import SwiftData

/// Writes confirmed sightings to the album (spec "Album store"): the frame goes to the `FrameStore`, the record to
/// SwiftData. One per app, over the container the screens query.
final class SightingRecorder {
    private static let logger = Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "album")
    /// Set once the sightings saved before rarity existed have been given theirs.
    static let rarityBackfilledKey = "rarityBackfilled"

    let container: ModelContainer
    let frames: FrameStore
    /// Where a card's rarity is read at the add (issue #52); nil records none, as before rarity existed.
    let rarity: RarityReader?

    init(container: ModelContainer, frames: FrameStore, rarity: RarityReader? = nil) {
        self.container = container
        self.frames = frames
        self.rarity = rarity
    }

    /// One written sighting and whether it earned the Legendary reveal.
    struct Recorded {
        let sighting: Sighting
        /// No other surviving sighting of the species existed when it was written: the card is Legendary.
        let isLegendary: Bool
    }

    /// Saves one sighting of `candidate`, with the JPEG `frame` captured when it was confirmed, if there was one. The
    /// sighting is a card from the start (issue #51): a stable identifier, the method Heard and, with a location, the
    /// rarity snapshot for its place and week (issue #52).
    @discardableResult
    func record(
        _ candidate: Candidate,
        confirmedAt: Date,
        location: Coordinate?,
        frame: Data?,
        source: SightingSource
    ) throws -> Recorded {
        let speciesID = candidate.species.birdnetLabel
        let context = container.mainContext
        let surviving = try context.fetch(FetchDescriptor<Sighting>(predicate: #Predicate { $0.speciesID == speciesID }))
        let isLegendary = CardCollection(sightings: surviving).addMakesLegendary(speciesID: speciesID)
        let sighting = Sighting(
            speciesID: speciesID,
            confirmedAt: confirmedAt,
            location: location,
            soundConfidence: Double(candidate.score),
            frameImagePath: try frame.map { try frames.write(jpeg: $0) },
            source: source,
            method: .heard
        )
        sighting.rarity = raritySnapshot(scientificName: candidate.species.scientificName, location: location, at: confirmedAt)
        context.insert(sighting)
        try context.save()
        return Recorded(sighting: sighting, isLegendary: isLegendary)
    }

    /// Gives each sighting saved before rarity existed its snapshot from its saved coordinate and date, once per album
    /// (issue #52). A sighting that already has one is never read again, and one without a location keeps none. The
    /// geomodel is read off the main actor; if a read fails, nothing is marked done and the next launch tries again.
    func backfillRarity(defaults: UserDefaults = .standard) async {
        guard let rarity, !defaults.bool(forKey: Self.rarityBackfilledKey) else { return }
        do {
            let context = container.mainContext
            let pending = try context.fetch(FetchDescriptor<Sighting>()).filter { $0.rarity == nil && $0.location != nil }
            let requests = pending.map { (scientificName: $0.scientificName, location: $0.location, date: $0.confirmedAt) }
            let snapshots = try await Task.detached(priority: .utility) {
                try requests.map { try rarity.snapshot(scientificName: $0.scientificName, location: $0.location, at: $0.date) }
            }.value
            for (sighting, snapshot) in zip(pending, snapshots) where !sighting.isDeleted && sighting.rarity == nil {
                sighting.rarity = snapshot
            }
            try context.save()
            defaults.set(true, forKey: Self.rarityBackfilledKey)
            Self.logger.info("rarity backfilled for \(snapshots.count { $0 != nil }, privacy: .public) sightings")
        } catch {
            Self.logger.error("rarity backfill failed, retried next launch: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The snapshot for an add; nil without a location or a reading, or when the geomodel can't be read (the card then
    /// says rarity is unavailable).
    private func raritySnapshot(scientificName: String, location: Coordinate?, at date: Date) -> RaritySnapshot? {
        do {
            return try rarity?.snapshot(scientificName: scientificName, location: location, at: date)
        } catch {
            Self.logger.error("rarity unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Removes a sighting and its files from the album.
    func delete(_ sighting: Sighting) throws {
        let files = sighting.filePaths
        container.mainContext.delete(sighting)
        try container.mainContext.save()
        for path in files { try? FileManager.default.removeItem(at: frames.url(for: path)) }
    }
}

extension RarityReader {
    /// The album's snapshot of the species at `location` in the week of `date`; nil without a location, or for a species
    /// the geomodel doesn't know.
    nonisolated func snapshot(scientificName: String, location: Coordinate?, at date: Date) throws -> RaritySnapshot? {
        guard let location else { return nil }
        let context = GeoContext(latitude: location.latitude, longitude: location.longitude, date: date)
        return try reading(scientificName: scientificName, in: context).map(RaritySnapshot.init)
    }
}

extension RaritySnapshot {
    /// The album's copy of a geomodel reading.
    nonisolated init(_ reading: RarityReading) {
        self.init(occurrence: Double(reading.occurrence), label: RarityLabel(reading.label), calibrationVersion: reading.calibrationVersion, week: reading.week)
    }
}

extension RarityLabel {
    nonisolated init(_ label: RarityReading.Label) {
        switch label {
        case .common: self = .common
        case .uncommon: self = .uncommon
        case .rare: self = .rare
        case .exceptional: self = .exceptional
        }
    }
}
