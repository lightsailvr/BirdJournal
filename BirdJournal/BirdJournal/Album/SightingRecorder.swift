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
            speciesID: candidate.species.birdnetLabel,
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

    /// A second confirmation of the same species in one run: the sighting keeps its first time and place, takes the
    /// latest confidence, and swaps in the new frame when there is one.
    func update(_ sighting: Sighting, with candidate: Candidate, frame: Data?) throws {
        sighting.soundConfidence = Double(candidate.score)
        if let frame {
            let previous = sighting.frameImagePath
            sighting.frameImagePath = try frames.write(jpeg: frame)
            if let previous { try? FileManager.default.removeItem(at: frames.url(for: previous)) }
        }
        try container.mainContext.save()
    }
}
