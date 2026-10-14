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

    /// One written sighting and whether it earned the Legendary reveal.
    struct Recorded {
        let sighting: Sighting
        /// No other surviving sighting of the species existed when it was written: the card is Legendary.
        let isLegendary: Bool
    }

    /// Saves one sighting of `candidate`, with the JPEG `frame` captured when it was confirmed, if there was one. The
    /// sighting is a card from the start (issue #51): a stable identifier and the method Heard.
    @discardableResult
    func record(
        _ candidate: Candidate,
        confirmedAt: Date,
        location: Coordinate?,
        frame: Data?,
        source: SightingSource
    ) throws -> Recorded {
        let speciesID = candidate.species.birdnetLabel
        let context = container.mainContext
        let surviving = try context.fetch(FetchDescriptor<Sighting>(predicate: #Predicate { $0.speciesID == speciesID }))
        let isLegendary = CardCollection(sightings: surviving).addMakesLegendary(speciesID: speciesID)
        let sighting = Sighting(
            speciesID: speciesID,
            confirmedAt: confirmedAt,
            location: location,
            soundConfidence: Double(candidate.score),
            frameImagePath: try frame.map { try frames.write(jpeg: $0) },
            source: source,
            method: .heard
        )
        context.insert(sighting)
        try context.save()
        return Recorded(sighting: sighting, isLegendary: isLegendary)
    }

    /// Removes a sighting and its files from the album.
    func delete(_ sighting: Sighting) throws {
        let files = sighting.filePaths
        container.mainContext.delete(sighting)
        try container.mainContext.save()
        for path in files { try? FileManager.default.removeItem(at: frames.url(for: path)) }
    }
}
