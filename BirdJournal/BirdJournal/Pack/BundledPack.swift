import Album
import Identification
import LensSession
import OSLog
import Pack
import UIKit

/// The species pack compiled into the app (DECISIONS.md, "Species pack": the LA pack ships in the binary so the
/// first launch works offline), read once per process, and the lens-facing lookups over it.
enum BundledPack {
    /// The pack, or the reason it could not be read (logged once). A missing or broken pack is not fatal: every
    /// species stays identifiable by name (spec user story 40).
    static let loaded: Result<SpeciesPack, any Error> = {
        let result = Result { try SpeciesPack.bundled() }
        if case .failure(let error) = result {
            Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "pack").error("bundled pack unavailable: \(String(describing: error))")
        }
        return result
    }()

    static var pack: SpeciesPack? { try? loaded.get() }

    /// What the species card shows: the best photo and the description fields the pack has. Until #12 fills field
    /// marks, size and habitat, the text falls back to the pack's summary, then (in the renderer) to the scientific
    /// name, and the size-and-habitat line is left out.
    static func profile(for species: Species) -> SpeciesProfile? {
        guard let pack, let entry = pack.species(scientificName: species.scientificName) else { return nil }
        let best = entry.photos.first
        return SpeciesProfile(
            photo: best.map { LensImage(id: $0.id) },
            fieldMarks: entry.fieldMarks ?? entry.summary ?? "",
            size: entry.size ?? "",
            habitat: entry.habitat ?? "",
            photoCredit: best?.shortCredit ?? ""
        )
    }

    /// The species name the album shows (issue #11): the pack's common name for the sighting's scientific name (the
    /// key the pack and the model share), else the label's own common name, so an unpacked species is still named.
    static func commonName(for sighting: Sighting) -> String {
        pack?.species(scientificName: sighting.scientificName)?.commonName ?? sighting.commonName
    }

    /// The lens crop for a photo the pack names (552 × 368 pixels, laid out at pixel size across the card, issue #24).
    static func image(for image: LensImage) -> UIImage? {
        guard let pack, let photo = pack.photo(id: image.id) else { return nil }
        return UIImage(contentsOfFile: pack.lensImageURL(for: photo).path())
    }
}
