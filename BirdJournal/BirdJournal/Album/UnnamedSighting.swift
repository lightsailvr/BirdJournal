import Album
import Foundation

/// An unnamed sighting as the screens and the run hold it (issue #188, of #185): what the album's `Capture` says, as a value.
/// A photo of a bird with its time, place and source, waiting for its name; naming it writes a sighting with all four. A value
/// and not the model, so a sheet naming it is not left holding a record that has since been named or deleted.
nonisolated struct UnnamedSighting: Identifiable, Hashable, Sendable {
    /// The capture's own identifier.
    let id: UUID
    /// When the photo was taken: the time of the sighting it becomes.
    let takenAt: Date
    /// Where the birder was when it was taken; nil when no place was known.
    let location: Coordinate?
    /// The photo, relative to the `FrameStore`.
    let photoPath: String
    /// The device that took the photo.
    let source: SightingSource
}

extension UnnamedSighting {
    init(_ capture: Capture) {
        self.init(id: capture.identifier, takenAt: capture.takenAt, location: capture.location, photoPath: capture.photoPath, source: capture.source)
    }
}
