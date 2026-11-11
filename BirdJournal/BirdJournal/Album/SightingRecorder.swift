import Album
import Foundation
import Identification
import ImageIO
import OSLog
import SwiftData
import UniformTypeIdentifiers

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
    /// The sets the phone knows when an add is written (issue #54), which place its sighting and so its patch; none
    /// places every sighting in Uncharted.
    var sets: () -> [CardSet] = { [] }

    init(container: ModelContainer, frames: FrameStore, rarity: RarityReader? = nil) {
        self.container = container
        self.frames = frames
        self.rarity = rarity
    }

    /// One written sighting, whether it sewed a patch, its patch's count with it, and its set and collector number.
    struct Recorded {
        let sighting: Sighting
        /// No other surviving sighting of the species was in its placement when it was written: it sewed the species'
        /// patch there (issue #132). Otherwise it was seen again.
        let sewsPatch: Bool
        /// The patch's sightings, this one included.
        let patchCount: Int
        let placement: CardPlacement
    }

    /// Saves one sighting of `candidate`, with the JPEG `frame` captured when it was confirmed, if there was one. The
    /// sighting is collected from the start (issue #51): a stable identifier, the method Heard and, with a location, the
    /// rarity snapshot for its place and week (issue #52), placed in its set as the collection will place it (#54),
    /// and either sewing its species' patch there or adding to it (#132).
    @discardableResult
    func record(
        _ candidate: Candidate,
        confirmedAt: Date,
        location: Coordinate?,
        frame: Data?,
        source: SightingSource,
        method: SightingMethod = .heard
    ) throws -> Recorded {
        try write(Sighting(
            speciesID: candidate.species.birdnetLabel,
            confirmedAt: confirmedAt,
            location: location,
            soundConfidence: Double(candidate.score),
            frameImagePath: try frame.map { try frames.write(jpeg: $0) },
            source: source,
            method: method
        ))
    }

    /// Writes a capture (issue #188, of #185): the photo as it came, with when and where it was taken and the device that
    /// took it. Called at the shutter, before any name, so nothing that happens next can lose the picture. It is no
    /// sighting: no rarity is read, no patch is sewn, and nothing is told to anyone.
    @discardableResult
    func recordCapture(photo: Data, takenAt: Date, location: Coordinate?, source: SightingSource) throws -> Capture {
        let path = try frames.write(photo, pathExtension: Self.pathExtension(of: photo))
        let capture = Capture(takenAt: takenAt, location: location, photoPath: path, source: source)
        let context = container.mainContext
        context.insert(capture)
        do {
            try context.save()
            return capture
        } catch {
            // No capture, so nothing would ever remove the file.
            context.delete(capture)
            try? FileManager.default.removeItem(at: frames.url(for: path))
            throw error
        }
    }

    /// Gives a capture written before its place was known that place (issue #191): with no run, a shutter can be quicker
    /// than the phone's first fix.
    func place(_ capture: Capture, at location: Coordinate) throws {
        let context = container.mainContext
        capture.location = location
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    /// Names a capture (issues #186 and #188, of #185): writes the sighting of `bird` it becomes, and the capture goes, in one
    /// save. The sighting is Seen and marked as named by the birder, with no match score, at the capture's own time and place
    /// and from its device, whenever it is named; the photo, the same file, is its original photo, one of the birder's own.
    /// From there it is a sighting like any other: its rarity is read for that place and week, it is placed in its set, and
    /// it sews its bird's patch there or adds to it.
    @discardableResult
    func name(_ capture: Capture, as bird: NameableBird) throws -> Recorded {
        let sighting = Sighting(speciesID: bird.speciesID, confirmedAt: capture.takenAt, location: capture.location, soundConfidence: 0, source: capture.source, method: .seen, namedByBirder: true)
        sighting.attachedPhotoPaths = [capture.photoPath]
        let context = container.mainContext
        context.delete(capture)
        do {
            return try write(sighting)
        } catch {
            // Neither half happened: the capture still waits, with its photo.
            context.rollback()
            throw error
        }
    }

    /// Takes a naming back: the sighting goes and its photo waits for a name again, as a capture with the sighting's time,
    /// place and source. Nil, with nothing changed, for a sighting that was not named from a photo it still has. Undo never
    /// removes a photo: only a delete does.
    func takeBackName(of sighting: Sighting) throws -> Capture? {
        guard sighting.namedByBirder, let photo = sighting.attachedPhotoPaths.first else { return nil }
        let others = sighting.filePaths.filter { $0 != photo }
        let capture = Capture(takenAt: sighting.confirmedAt, location: sighting.location, photoPath: photo, source: sighting.source)
        let context = container.mainContext
        context.insert(capture)
        context.delete(sighting)
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        for path in others { try? FileManager.default.removeItem(at: frames.url(for: path)) }
        return capture
    }

    /// Changes the bird of a sighting (issue #190, of #185): the same sighting, with its identifier, photo, time, place,
    /// source and note, now of `bird`. Only its bird is written; patches are derived from sightings, so the old bird's patch
    /// loses this one, and is unpicked if it had no other there, and the new bird's gains it or is sewn, which is what the
    /// answer says. What was read or written for the old bird does not stay: the rarity is read again for the new bird at
    /// the sighting's own place and week, and the caption goes. One save, or nothing changes.
    @discardableResult
    func changeBird(of sighting: Sighting, to bird: NameableBird) throws -> Recorded {
        let speciesID = bird.speciesID
        let location = sighting.location
        let identifier = sighting.identifier
        let context = container.mainContext
        let others = try context.fetch(FetchDescriptor<Sighting>(predicate: #Predicate { $0.speciesID == speciesID && $0.identifier != identifier }))
        let sets = sets()
        let existing = CardCollection(sightings: others, sets: sets).count(ofSpeciesID: speciesID, at: location)
        sighting.speciesID = speciesID
        sighting.rarity = raritySnapshot(scientificName: bird.scientificName, location: location, at: sighting.confirmedAt)
        sighting.caption = nil
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        return Recorded(sighting: sighting, sewsPatch: existing == 0, patchCount: existing + 1, placement: CardSet.placement(speciesID: speciesID, at: location, in: sets))
    }

    /// Removes a capture and its photo from the album: the one thing that loses a photo.
    func delete(_ capture: Capture) throws {
        let path = capture.photoPath
        container.mainContext.delete(capture)
        try container.mainContext.save()
        try? FileManager.default.removeItem(at: frames.url(for: path))
    }

    /// The capture with `identifier`, while it still waits for its name.
    func capture(_ identifier: UUID) -> Capture? {
        try? container.mainContext.fetch(FetchDescriptor<Capture>(predicate: #Predicate { $0.identifier == identifier })).first
    }

    /// Writes a new sighting with the rarity for its place and week, and says what it did to its bird's patch.
    private func write(_ sighting: Sighting) throws -> Recorded {
        let speciesID = sighting.speciesID
        let location = sighting.location
        let context = container.mainContext
        let surviving = try context.fetch(FetchDescriptor<Sighting>(predicate: #Predicate { $0.speciesID == speciesID }))
        let sets = sets()
        let existing = CardCollection(sightings: surviving, sets: sets).count(ofSpeciesID: speciesID, at: location)
        sighting.rarity = raritySnapshot(scientificName: sighting.scientificName, location: location, at: sighting.confirmedAt)
        context.insert(sighting)
        try context.save()
        return Recorded(sighting: sighting, sewsPatch: existing == 0, patchCount: existing + 1, placement: CardSet.placement(speciesID: speciesID, at: location, in: sets))
    }

    /// The extension a photo's file takes, from what the picture is (a camera gives HEIC or JPEG); "jpg" when it can't be told.
    static func pathExtension(of photo: Data) -> String {
        guard let source = CGImageSourceCreateWithData(photo as CFData, nil), let type = CGImageSourceGetType(source) else { return "jpg" }
        return UTType(type as String)?.preferredFilenameExtension ?? "jpg"
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
