import Album
import Foundation
import Identification
import Observation
import SwiftData

/// The sightings one listening run has written to the album (issue #28), shared by the glasses' "Add to my list" and
/// the phone's "Add to journal". Every add writes a new sighting, with its own time, place and photo, so the same bird
/// can be added as often as the birder likes (user's choice, 2026-10-10, replacing spec user story 33's one sighting
/// per species and run); an addition can be undone, which removes that sighting.
@MainActor
@Observable
final class RunSightings {
    /// One sighting added this run, as the screens list it.
    struct Entry: Identifiable, Equatable {
        let id: PersistentIdentifier
        var candidate: Candidate
        var hasFrame: Bool
    }

    /// What one add did, so it can be undone, and the card it earned.
    struct Addition: Equatable {
        let species: Species
        let sightingID: PersistentIdentifier
        /// The sighting's stable identifier.
        let identifier: UUID
        /// The add was the birder's first surviving sighting of the species: a Legendary card, revealed once.
        let isLegendary: Bool
    }

    /// In add order.
    private(set) var entries: [Entry] = []
    @ObservationIgnored private var records: [PersistentIdentifier: Sighting] = [:]
    @ObservationIgnored let recorder: SightingRecorder

    init(recorder: SightingRecorder) {
        self.recorder = recorder
    }

    /// Forgets the run's sightings; the album keeps them. Called at the start of a run.
    func reset() {
        entries = []
        records = [:]
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
    func add(_ candidate: Candidate, confirmedAt: Date, location: Coordinate?, frame: Data?, source: SightingSource) throws -> Addition {
        let recorded = try recorder.record(candidate, confirmedAt: confirmedAt, location: location, frame: frame, source: source)
        let sighting = recorded.sighting
        records[sighting.persistentModelID] = sighting
        entries.append(Entry(id: sighting.persistentModelID, candidate: candidate, hasFrame: frame != nil))
        return Addition(species: candidate.species, sightingID: sighting.persistentModelID, identifier: sighting.identifier, isLegendary: recorded.isLegendary)
    }

    /// Takes an addition back: its sighting is deleted with its frame. Nothing happens if it is already gone.
    func undo(_ addition: Addition) throws {
        guard let sighting = records[addition.sightingID] else { return }
        try recorder.delete(sighting)
        records[addition.sightingID] = nil
        entries.removeAll { $0.id == addition.sightingID }
    }
}
