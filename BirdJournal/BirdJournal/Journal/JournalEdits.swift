import Album
import Foundation
import ImageIO
import Observation
import OSLog
import SwiftData
import UniformTypeIdentifiers

/// Edits to the journal from the phone (issue #28): a note on a sighting, Heard or Seen (issue #52), the birder's own photo
/// (issue #137), and a removal that can be taken back for a few seconds. A removed sighting's record is kept here with its files on disk until the
/// window closes; Undo puts it back as a new record with the same fields, its identifier included, so the same card
/// returns (issue #51).
@MainActor
@Observable
final class JournalEdits {
    /// What a removed sighting was, so it can come back.
    struct Removed: Identifiable, Equatable {
        let id = UUID()
        let identifier: UUID
        let speciesID: String
        let confirmedAt: Date
        let location: Coordinate?
        let soundConfidence: Double
        let frameImagePath: String?
        let source: SightingSource
        let note: String?
        let method: SightingMethod
        let rarity: RaritySnapshot?
        let caption: CardCaption?
        let art: CardArt
        let attachedPhotoPaths: [String]
        let filePaths: [String]
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
    /// Keeps a published sighting's find in step (issue #62): Heard or Seen puts it again, a removal deletes it, and
    /// Undo puts it back. Nil changes nothing on the server.
    @ObservationIgnored var findOutbox: FindOutbox?

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

    /// Saves how the birder met the bird, from the card's back.
    func setMethod(_ method: SightingMethod, on sighting: Sighting) {
        guard sighting.method != method else { return }
        sighting.method = method
        save()
        findOutbox?.changed(sighting.identifier)
    }

    enum AttachFailure: Error, Equatable {
        case unreadable
    }

    /// Keeps a photo from the library with the sighting, as it came, so it is the sighting's original and goes with it. A
    /// find carries no photo, so nothing reaches the server: only a card shared by hand can, through `SharedPhoto`.
    func attachPhoto(_ data: Data, to sighting: Sighting) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source),
              let pathExtension = UTType(type as String)?.preferredFilenameExtension else { throw AttachFailure.unreadable }
        sighting.attachedPhotoPaths.append(try frames.write(data, pathExtension: pathExtension))
        save()
    }

    /// Takes an attached photo off the sighting, with its file. A card already shared keeps the prepared copy it sent.
    func removeAttachedPhoto(_ path: String, from sighting: Sighting) {
        sighting.attachedPhotoPaths.removeAll { $0 == path }
        save()
        try? FileManager.default.removeItem(at: frames.url(for: path))
    }

    /// Removes the sighting from the journal, keeping what it was for `undoWindow`.
    func remove(_ sighting: Sighting, commonName: String) {
        commitPendingRemoval()
        let removed = Removed(
            identifier: sighting.identifier, speciesID: sighting.speciesID, confirmedAt: sighting.confirmedAt, location: sighting.location,
            soundConfidence: sighting.soundConfidence, frameImagePath: sighting.frameImagePath, source: sighting.source,
            note: sighting.note, method: sighting.method, rarity: sighting.rarity, caption: sighting.caption, art: sighting.art,
            attachedPhotoPaths: sighting.attachedPhotoPaths, filePaths: sighting.filePaths, commonName: commonName
        )
        container.mainContext.delete(sighting)
        save()
        // At once, not when the undo window closes: a quit in the window must not leave the find behind.
        findOutbox?.removed(removed.identifier)
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
        let sighting = Sighting(
            identifier: removed.identifier, speciesID: removed.speciesID, confirmedAt: removed.confirmedAt, location: removed.location,
            soundConfidence: removed.soundConfidence, frameImagePath: removed.frameImagePath, source: removed.source,
            note: removed.note, method: removed.method
        )
        sighting.rarity = removed.rarity
        sighting.caption = removed.caption
        sighting.art = removed.art
        sighting.attachedPhotoPaths = removed.attachedPhotoPaths
        container.mainContext.insert(sighting)
        save()
        findOutbox?.restored(removed.identifier)
    }

    /// Lets the last removal stand: its files leave the disk.
    func commitPendingRemoval() {
        expiry?.cancel()
        expiry = nil
        guard let removed = pendingRemoval else { return }
        pendingRemoval = nil
        for path in removed.filePaths {
            try? FileManager.default.removeItem(at: frames.url(for: path))
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
