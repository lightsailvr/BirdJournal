import Album
import Foundation
import Identification
import Observation
import SwiftData

/// The sightings one listening run has written to the album (issue #28), shared by the glasses' "Add to my list" and
/// the phone's "Add to collection". Every add writes a new sighting, with its own time, place and photo, so the same bird
/// can be added as often as the birder likes (user's choice, 2026-10-10, replacing spec user story 33's one sighting
/// per species and run); an addition can be undone, which removes that sighting.
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

    /// In add order.
    private(set) var entries: [Entry] = []
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
        if let captioner { Task { await captioner.caption(sighting) } }
        findOutbox?.added(sighting.identifier, isNewPatch: recorded.sewsPatch)
        return Addition(species: candidate.species, sightingID: sighting.persistentModelID, identifier: sighting.identifier, sewsPatch: recorded.sewsPatch, patchCount: recorded.patchCount, placement: recorded.placement)
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

    /// Takes an addition back: its sighting is deleted with its frame. Nothing happens if it is already gone.
    func undo(_ addition: Addition) throws {
        guard let sighting = records[addition.sightingID] else { return }
        try recorder.delete(sighting)
        findOutbox?.removed(addition.identifier)
        records[addition.sightingID] = nil
        entries.removeAll { $0.id == addition.sightingID }
    }
}
