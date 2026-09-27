import Album
import Foundation
import Identification
import SwiftData

/// Writes confirmed sightings to the album (spec "Album store"): the frame goes to the `FrameStore`, the record to
/// SwiftData. One per app, over the container the screens query.
final class SightingRecorder {
    let container: ModelContainer
    let frames: FrameStore

    init(container: ModelContainer, frames: FrameStore) {
        self.container = container
        self.frames = frames
    }

    /// Saves one sighting of `candidate`, with the JPEG `frame` captured when it was confirmed, if there was one.
    @discardableResult
    func record(
        _ candidate: Candidate,
        confirmedAt: Date,
        location: Coordinate?,
        frame: Data?,
        source: SightingSource
    ) throws -> Sighting {
        let sighting = Sighting(
            speciesID: Self.speciesID(for: candidate.species),
            confirmedAt: confirmedAt,
            location: location,
            soundConfidence: Double(candidate.score),
            frameImagePath: try frame.map { try frames.write(jpeg: $0) },
            source: source
        )
        let context = container.mainContext
        context.insert(sighting)
        try context.save()
        return sighting
    }

    /// The BirdNET label the album keys species by, e.g. "Sayornis nigricans_Black Phoebe".
    static func speciesID(for species: Species) -> String {
        "\(species.scientificName)_\(species.commonName)"
    }
}
