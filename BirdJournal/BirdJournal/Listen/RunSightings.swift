import Album
import Foundation
import Identification
import Observation
import SwiftData

/// The sightings one listening run has written to the album (issue #28), shared by the glasses' "Add to my list", the
/// phone's "Add to collection" and the birds seen and named from a photo (issue #186). Every add writes a new sighting,
/// with its own time, place and photo, so the same bird can be added as often as the birder likes (user's choice,
/// 2026-10-10, replacing spec user story 33's one sighting per species and run); an addition can be undone, which removes
/// that sighting.
@MainActor
@Observable
final class RunSightings {
    /// One sighting added this run, as the screens list it.
    struct Entry: Identifiable, Equatable {
        let id: PersistentIdentifier
        /// The sighting's stable identifier, which the collection knows it by.
        let identifier: UUID
        var candidate: Candidate
        var hasFrame: Bool
    }

    /// One bird seen this run (issue #186): a photo the birder took and named, written as a sighting. No candidate stands
    /// behind it, so it is listed apart from the adds of what was heard.
    struct Seen: Identifiable, Equatable {
        let id: PersistentIdentifier
        /// The sighting's stable identifier, which the collection knows it by.
        let identifier: UUID
        /// The BirdNET label the sighting is written under.
        let speciesID: String
        let scientificName: String
        /// The label's own name, for when no pack on the phone names the bird.
        let commonName: String
        /// When the photo was taken.
        let seenAt: Date
        /// The photo, relative to the `FrameStore`.
        let photoPath: String?

        init(_ sighting: Sighting) {
            id = sighting.persistentModelID
            identifier = sighting.identifier
            speciesID = sighting.speciesID
            scientificName = sighting.scientificName
            commonName = sighting.commonName
            seenAt = sighting.confirmedAt
            photoPath = sighting.attachedPhotoPaths.first
        }
    }

    /// What one add did, so it can be undone, and what it earned: a new patch, or another sighting of one.
    struct Addition: Equatable {
        let species: Species
        let sightingID: PersistentIdentifier
        /// The sighting's stable identifier.
        let identifier: UUID
        /// The add was the species' first surviving sighting in its placement: it sewed the patch, revealed once
        /// (issue #132). Otherwise it was seen again.
        let sewsPatch: Bool
        /// The patch's sightings after the add.
        let patchCount: Int
        /// The set and collector number (issue #54).
        let placement: CardPlacement
    }

    /// The adds of birds heard, in add order.
    private(set) var entries: [Entry] = []
    /// The birds seen and named, in add order.
    private(set) var seen: [Seen] = []
    /// Every sighting this run has written and not undone, heard or seen, in add order: what a recap counts its patches from.
    private(set) var identifiers: [UUID] = []
    /// The photos taken this run and not yet named (issue #188), in the order taken. They are in the album from the shutter
    /// on, and are no sightings: none is among `identifiers`.
    private(set) var unnamed: [UnnamedSighting] = []
    @ObservationIgnored private var records: [PersistentIdentifier: Sighting] = [:]
    @ObservationIgnored let recorder: SightingRecorder
    /// Writes each add's caption after the sighting is written, never blocking it (issue #56); nil writes none.
    @ObservationIgnored var captioner: Captioner?
    /// Publishes each add as a find when the birder is signed in and sharing, and deletes it when the add is undone
    /// (issue #62); nil publishes nothing.
    @ObservationIgnored var findOutbox: FindOutbox?

    init(recorder: SightingRecorder) {
        self.recorder = recorder
    }

    /// Forgets the run's sightings; the album keeps them. Called at the start of a run.
    func reset() {
        entries = []
        seen = []
        identifiers = []
        unnamed = []
        records = [:]
    }

    /// Reads back a run's adds from the album, for its review after the app was killed: Undo still works on them. A sighting
    /// deleted meanwhile is left out.
    func restore(_ added: [(identifier: UUID, candidate: Candidate)]) {
        let context = recorder.container.mainContext
        for (identifier, candidate) in added {
            guard let sighting = try? context.fetch(FetchDescriptor<Sighting>(predicate: #Predicate { $0.identifier == identifier })).first else { continue }
            records[sighting.persistentModelID] = sighting
            entries.append(Entry(id: sighting.persistentModelID, identifier: identifier, candidate: candidate, hasFrame: sighting.frameImagePath != nil))
            identifiers.append(identifier)
        }
    }

    /// Reads back the birds a run saw, as `restore` does its adds.
    func restoreSeen(_ identifiers: [UUID]) {
        let context = recorder.container.mainContext
        for identifier in identifiers {
            guard let sighting = try? context.fetch(FetchDescriptor<Sighting>(predicate: #Predicate { $0.identifier == identifier })).first else { continue }
            records[sighting.persistentModelID] = sighting
            seen.append(Seen(sighting))
            self.identifiers.append(identifier)
        }
    }

    /// `date`, or just after the newest sighting this run has added if that's later: what keeps adds with one date in order.
    func nextDate(atOrAfter date: Date) -> Date {
        guard let newest = records.values.map(\.confirmedAt).max(), newest >= date else { return date }
        return newest.addingTimeInterval(0.001)
    }

    func isAdded(_ species: Species) -> Bool {
        entries.contains { $0.candidate.species == species }
    }

    /// How many sightings of `species` this run has added.
    func count(of species: Species) -> Int {
        entries.count { $0.candidate.species == species }
    }

    /// Writes a new sighting of `candidate` to the album.
    @discardableResult
    func add(_ candidate: Candidate, confirmedAt: Date, location: Coordinate?, frame: Data?, source: SightingSource, method: SightingMethod = .heard) throws -> Addition {
        let recorded = try recorder.record(candidate, confirmedAt: confirmedAt, location: location, frame: frame, source: source, method: method)
        let sighting = recorded.sighting
        records[sighting.persistentModelID] = sighting
        entries.append(Entry(id: sighting.persistentModelID, identifier: sighting.identifier, candidate: candidate, hasFrame: frame != nil))
        return added(recorded, species: candidate.species)
    }

    /// Writes `photo` to the album as an unnamed sighting of this run (issue #188): at the shutter, before any name. It earns
    /// nothing and is told to nobody until it is named.
    /// - Parameters:
    ///   - location: where the birder was when the photo was taken.
    ///   - source: the device that took the photo.
    ///   - onThisRun: false for a photo taken with no run under way (issue #191): it is written to the album the same way
    ///     and is on no run's list, like one an earlier run left unnamed.
    @discardableResult
    func capture(photo: Data, takenAt: Date, location: Coordinate?, source: SightingSource, onThisRun: Bool = true) throws -> UnnamedSighting {
        let captured = UnnamedSighting(try recorder.recordCapture(photo: photo, takenAt: takenAt, location: location, source: source))
        if onThisRun { unnamed.append(captured) }
        return captured
    }

    /// Names an unnamed sighting (issues #186 and #188): writes the sighting of `bird` it becomes, at the photo's own time and
    /// place, and from here on an add like any other, with its caption, its find and its Undo. One this run took moves to
    /// the birds seen on it; one from an earlier run is named all the same, and is no part of this run.
    @discardableResult
    func name(_ unnamed: UnnamedSighting, as bird: NameableBird) throws -> Addition {
        guard let capture = recorder.capture(unnamed.id) else { throw UnnamedSightingFailure.gone }
        let recorded = try recorder.name(capture, as: bird)
        let sighting = recorded.sighting
        records[sighting.persistentModelID] = sighting
        let isOfThisRun = self.unnamed.contains { $0.id == unnamed.id }
        if isOfThisRun {
            self.unnamed.removeAll { $0.id == unnamed.id }
            seen.append(Seen(sighting))
        }
        // No row of the model's output stands behind it: only the names matter to what reads an addition.
        return added(recorded, species: Species(index: 0, scientificName: bird.scientificName, commonName: bird.commonName, taxonomicClass: Species.birds), isOfThisRun: isOfThisRun)
    }

    /// A photo taken and named in one step: `capture`, then `name`. If the naming fails the photo is kept, unnamed.
    /// - Parameter source: the device that took the photo.
    @discardableResult
    func addSeen(_ bird: NameableBird, photo: Data, takenAt: Date, location: Coordinate?, source: SightingSource) throws -> Addition {
        try name(capture(photo: photo, takenAt: takenAt, location: location, source: source), as: bird)
    }

    /// Removes an unnamed sighting and its photo, from the album and from the run. Nothing happens if it is already gone.
    func delete(_ unnamed: UnnamedSighting) throws {
        if let capture = recorder.capture(unnamed.id) { try recorder.delete(capture) }
        self.unnamed.removeAll { $0.id == unnamed.id }
    }

    /// Reads back the photos a run took and hadn't named, as `restore` does its adds. One named or deleted meanwhile is left out.
    func restoreUnnamed(_ identifiers: [UUID]) {
        unnamed += identifiers.compactMap { recorder.capture($0).map(UnnamedSighting.init) }
    }

    /// Whether `addition` can still be taken back: its sighting was written through this ledger and hasn't been undone.
    func canUndo(_ addition: Addition) -> Bool {
        records[addition.sightingID] != nil
    }

    /// What every add does once its sighting is written: the caption, the find, and what it earned.
    private func added(_ recorded: SightingRecorder.Recorded, species: Species, isOfThisRun: Bool = true) -> Addition {
        let sighting = recorded.sighting
        if isOfThisRun { identifiers.append(sighting.identifier) }
        if let captioner { Task { await captioner.caption(sighting) } }
        findOutbox?.added(sighting.identifier, isNewPatch: recorded.sewsPatch)
        return Addition(species: species, sightingID: sighting.persistentModelID, identifier: sighting.identifier, sewsPatch: recorded.sewsPatch, patchCount: recorded.patchCount, placement: recorded.placement)
    }

    /// The add of the sighting `identifier` as the album has it now, if that sighting is still the one that sewed its patch;
    /// nil once it's been deleted. What a ceremony that waited for the run to end shows, perhaps a launch or two later.
    func sewnAddition(of identifier: UUID) -> Addition? {
        let context = recorder.container.mainContext
        guard let sighting = try? context.fetch(FetchDescriptor<Sighting>(predicate: #Predicate { $0.identifier == identifier })).first else { return nil }
        let speciesID = sighting.speciesID
        let ofSpecies = (try? context.fetch(FetchDescriptor<Sighting>(predicate: #Predicate { $0.speciesID == speciesID }))) ?? [sighting]
        guard let patch = CardCollection(sightings: ofSpecies, sets: recorder.sets()).patch(of: identifier), patch.sewn.identifier == identifier else { return nil }
        let species = Species(index: 0, scientificName: sighting.scientificName, commonName: sighting.commonName, taxonomicClass: "Aves")
        return Addition(species: species, sightingID: sighting.persistentModelID, identifier: identifier, sewsPatch: true, patchCount: patch.count, placement: patch.placement)
    }

    /// Takes an addition back. The sighting of a bird heard is deleted with its frame and its photos. The naming of a photo
    /// is taken back and the photo kept (issue #188): the sighting goes, and the unnamed sighting waits again, on this run's
    /// list if this run took it. Nothing happens if the sighting is already gone.
    func undo(_ addition: Addition) throws {
        guard let sighting = records[addition.sightingID] else { return }
        let wasSeenThisRun = seen.contains { $0.id == addition.sightingID }
        if let capture = try recorder.takeBackName(of: sighting) {
            if wasSeenThisRun {
                unnamed.append(UnnamedSighting(capture))
                unnamed.sort { $0.takenAt < $1.takenAt }
            }
        } else {
            try recorder.delete(sighting)
        }
        findOutbox?.removed(addition.identifier)
        records[addition.sightingID] = nil
        entries.removeAll { $0.id == addition.sightingID }
        seen.removeAll { $0.id == addition.sightingID }
        identifiers.removeAll { $0 == addition.identifier }
    }
}

/// Why an unnamed sighting could not be named.
enum UnnamedSightingFailure: Error, Equatable, LocalizedError {
    /// It has been named or deleted since the screen showing it was drawn.
    case gone

    var errorDescription: String? {
        switch self {
        case .gone: "This photo has already been named or deleted."
        }
    }
}
