import Album
import Foundation
import Identification
import Observation
import SwiftData

/// The sightings one listening run has written to the album (issue #28), shared by the glasses' "Add to my list" and
/// the phone's "Add to journal" so both count the same species once. A species added again in the same run updates
/// its sighting rather than adding a second (spec user story 33); an addition can be undone, which removes a new
/// sighting or puts an updated one back as it was.
@MainActor
@Observable
final class RunSightings {
    /// One species added this run, as the screens list it.
    struct Entry: Identifiable, Equatable {
        let id: PersistentIdentifier
        var candidate: Candidate
        var hasFrame: Bool
    }

    /// What one add did, so it can be undone.
    struct Addition: Equatable {
        let species: Species
        let sightingID: PersistentIdentifier
        /// True when the add wrote a new sighting; false when it updated the run's earlier one.
        let wasNew: Bool
        /// The confidence and frame before an update, for the undo.
        let previousConfidence: Double?
        let previousFramePath: String?
    }

    /// In first-add order.
    private(set) var entries: [Entry] = []
    @ObservationIgnored private var records: [Species: Sighting] = [:]
    /// Frames an update replaced, kept on disk while the update can still be undone.
    @ObservationIgnored private var replacedFrames: [PersistentIdentifier: [String]] = [:]
    @ObservationIgnored let recorder: SightingRecorder

    init(recorder: SightingRecorder) {
        self.recorder = recorder
    }

    /// Forgets the run's species; the album keeps its sightings. Called at the start of a run.
    func reset() {
        commitReplacedFrames()
        entries = []
        records = [:]
    }

    /// Deletes the frames that updates replaced: the undo window has closed, so the earlier pictures are not coming
    /// back. Called when an acknowledgment expires and when the next run starts.
    func commitReplacedFrames() {
        for path in replacedFrames.values.flatMap({ $0 }) {
            try? FileManager.default.removeItem(at: recorder.frames.url(for: path))
        }
        replacedFrames = [:]
    }

    func isAdded(_ species: Species) -> Bool {
        records[species] != nil
    }

    func entry(for species: Species) -> Entry? {
        entries.first { $0.candidate.species == species }
    }

    /// Writes `candidate` to the album, or updates the sighting this run already wrote for its species.
    @discardableResult
    func add(_ candidate: Candidate, confirmedAt: Date, location: Coordinate?, frame: Data?, source: SightingSource) throws -> Addition {
        if let existing = records[candidate.species], let position = entries.firstIndex(where: { $0.id == existing.persistentModelID }) {
            let previous = (existing.soundConfidence, existing.frameImagePath)
            try recorder.update(existing, with: candidate, frame: frame)
            if frame != nil, let replaced = previous.1, replaced != existing.frameImagePath {
                replacedFrames[existing.persistentModelID, default: []].append(replaced)
            }
            entries[position].candidate = candidate
            if frame != nil { entries[position].hasFrame = true }
            return Addition(species: candidate.species, sightingID: existing.persistentModelID, wasNew: false, previousConfidence: previous.0, previousFramePath: previous.1)
        }
        let sighting = try recorder.record(candidate, confirmedAt: confirmedAt, location: location, frame: frame, source: source)
        records[candidate.species] = sighting
        entries.append(Entry(id: sighting.persistentModelID, candidate: candidate, hasFrame: frame != nil))
        return Addition(species: candidate.species, sightingID: sighting.persistentModelID, wasNew: true, previousConfidence: nil, previousFramePath: nil)
    }

    /// Takes an addition back: a new sighting is deleted with its frame; an updated one gets its earlier confidence
    /// and frame back. Nothing happens if the run has moved on from that sighting.
    func undo(_ addition: Addition) throws {
        guard let sighting = records[addition.species], sighting.persistentModelID == addition.sightingID else { return }
        if addition.wasNew {
            try recorder.delete(sighting)
            records[addition.species] = nil
            entries.removeAll { $0.id == addition.sightingID }
        } else if let position = entries.firstIndex(where: { $0.id == addition.sightingID }) {
            try recorder.restore(sighting, confidence: addition.previousConfidence ?? sighting.soundConfidence, framePath: addition.previousFramePath)
            if let previous = addition.previousFramePath {
                replacedFrames[addition.sightingID]?.removeAll { $0 == previous }  // back in use, not to be deleted
            }
            entries[position].candidate.score = Float(sighting.soundConfidence)
            entries[position].hasFrame = sighting.frameImagePath != nil
        }
    }
}
