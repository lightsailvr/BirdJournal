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

    /// What the lens pages show for a species: its best photo and the description fields the pack has. Until #12
    /// fills field marks, size and habitat, the field marks fall back to the scientific name and the size-and-habitat
    /// line is left out.
    static func profile(for species: Species) -> SpeciesProfile? {
        guard let pack, let entry = pack.species(scientificName: species.scientificName) else { return nil }
        let best = entry.photos.first
        return SpeciesProfile(
            photo: best.map { LensImage(id: $0.id) },
            fieldMarks: entry.fieldMarks ?? entry.scientificName,
            size: entry.size ?? "",
            habitat: entry.habitat ?? "",
            photoCredit: best?.shortCredit ?? "No photo in your pack"
        )
    }

    /// The lens-sized crop for a photo the pack names (260 pixels square, laid out at pixel size on the lens).
    static func image(for image: LensImage) -> UIImage? {
        guard let pack, let photo = pack.photo(id: image.id) else { return nil }
        return UIImage(contentsOfFile: pack.lensImageURL(for: photo).path())
    }
}
