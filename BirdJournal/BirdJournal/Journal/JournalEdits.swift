import Album
import Foundation
import Observation
import OSLog
import SwiftData

/// Edits to the journal from the phone (issue #28): a note on a sighting, and a removal that can be taken back for a
/// few seconds. A removed sighting's record is kept here with its frame on disk until the window closes; Undo puts
/// it back as a new record with the same fields.
@MainActor
@Observable
final class JournalEdits {
    /// What a removed sighting was, so it can come back.
    struct Removed: Identifiable, Equatable {
        let id = UUID()
        let speciesID: String
        let confirmedAt: Date
        let location: Coordinate?
        let soundConfidence: Double
        let frameImagePath: String?
        let source: SightingSource
        let note: String?
        let commonName: String
    }

    private static let logger = Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "journal")
    static let undoWindow: Duration = .seconds(8)

    /// The sighting removed last, while it can still be restored.
    private(set) var pendingRemoval: Removed?
    var errorMessage: String?

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let frames: FrameStore
    @ObservationIgnored private var expiry: Task<Void, Never>?

    init(container: ModelContainer, frames: FrameStore) {
        self.container = container
        self.frames = frames
    }

    /// Saves the note; an empty one clears it.
    func setNote(_ text: String, on sighting: Sighting) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = trimmed.isEmpty ? nil : trimmed
        guard sighting.note != note else { return }
        sighting.note = note
        save()
    }

    /// Removes the sighting from the journal, keeping what it was for `undoWindow`.
    func remove(_ sighting: Sighting, commonName: String) {
        commitPendingRemoval()
        let removed = Removed(
            speciesID: sighting.speciesID, confirmedAt: sighting.confirmedAt, location: sighting.location,
            soundConfidence: sighting.soundConfidence, frameImagePath: sighting.frameImagePath, source: sighting.source,
            note: sighting.note, commonName: commonName
        )
        container.mainContext.delete(sighting)
        save()
        pendingRemoval = removed
        expiry = Task { [weak self] in
            try? await Task.sleep(for: Self.undoWindow)
            guard !Task.isCancelled else { return }
            self?.commitPendingRemoval()
        }
    }

    /// Puts the last removed sighting back.
    func undoRemoval() {
        guard let removed = pendingRemoval else { return }
        expiry?.cancel()
        expiry = nil
        pendingRemoval = nil
        container.mainContext.insert(Sighting(
            speciesID: removed.speciesID, confirmedAt: removed.confirmedAt, location: removed.location,
            soundConfidence: removed.soundConfidence, frameImagePath: removed.frameImagePath, source: removed.source, note: removed.note
        ))
        save()
    }

    /// Lets the last removal stand: its frame leaves the disk.
    func commitPendingRemoval() {
        expiry?.cancel()
        expiry = nil
        guard let removed = pendingRemoval else { return }
        pendingRemoval = nil
        if let frame = removed.frameImagePath {
            try? FileManager.default.removeItem(at: frames.url(for: frame))
        }
    }

    private func save() {
        do {
            try container.mainContext.save()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            Self.logger.error("journal save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
