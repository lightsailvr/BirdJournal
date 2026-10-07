import Album
import Identification
import LensSession
import OSLog
import Pack
import UIKit

/// The app's packs: the Los Angeles pack compiled into the binary (DECISIONS.md, "Species pack": the first launch
/// works offline) and every pack downloaded from the index (issue #13), read as one. The lens-facing lookups over
/// them live here; the library itself is in the `Pack` module.
extension PackLibrary {
    private static let log = Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "pack")

    /// The library the app runs on: the bundled pack (a missing or broken one is logged, not fatal: every species
    /// stays identifiable by name, spec user story 40), the downloads under Application Support, and the index on
    /// GitHub Releases. In debug builds `-packIndexURL <url>` points the index elsewhere, for simulator runs against a
    /// local server.
    static func forApp() -> PackLibrary {
        let bundled: SpeciesPack?
        do {
            bundled = try SpeciesPack.bundled()
        } catch {
            log.error("bundled pack unavailable: \(String(describing: error))")
            bundled = nil
        }
        let storage: PackStorage
        do {
            storage = try PackStorage.applicationSupport()
        } catch {
            // Downloads into tmp would not survive a purge; the packs screen then shows what it finds there, if anything.
            log.error("Application Support unavailable, packs go to tmp: \(error.localizedDescription)")
            storage = PackStorage(directory: URL.temporaryDirectory.appending(path: "Packs", directoryHint: .isDirectory))
        }
        var indexURL = PackIndex.defaultURL
        #if DEBUG
        if let override = UserDefaults.standard.string(forKey: "packIndexURL").flatMap(URL.init(string:)) { indexURL = override }
        #endif
        return PackLibrary(bundled: bundled, storage: storage, indexURL: indexURL)
    }

    /// What the species card shows: the best photo and the description fields the first pack that has the species
    /// gives (issue #12). A species without field marks falls back to the pack's summary, then (in the renderer) to
    /// the scientific name, and the size-and-habitat line is left out when both are empty. The species' reference
    /// clips, song first, are what a tap on its photo page plays (issue #41).
    func profile(for species: Species) -> SpeciesProfile? {
        guard let entry = self.species(scientificName: species.scientificName)?.species else { return nil }
        let best = entry.photos.first
        return SpeciesProfile(
            photo: best.map { LensImage(id: $0.id) },
            fieldMarks: entry.fieldMarks ?? entry.summary ?? "",
            size: entry.size ?? "",
            habitat: entry.habitat ?? "",
            photoCredit: best?.shortCredit ?? "",
            sounds: entry.sounds.map { LensSound(id: $0.id, kind: LensSoundKind($0.kind)) }
        )
    }

    /// The clip a lens card names by id, with its file, from the first pack that has it.
    func soundAndFile(id: String) -> (sound: PackSound, url: URL)? {
        sound(id: id).map { ($0.sound, $0.pack.soundURL(for: $0.sound)) }
    }

    /// The species name the album shows (issue #11): a pack's common name for the sighting's scientific name (the
    /// key the packs and the model share), else the label's own common name, so an unpacked species is still named.
    func commonName(for sighting: Sighting) -> String {
        species(scientificName: sighting.scientificName)?.species.commonName ?? sighting.commonName
    }

    /// The lens crop for a photo a pack names (552 × 368 pixels, laid out at pixel size across the card, issue #24).
    func image(for image: LensImage) -> UIImage? {
        guard let found = photo(id: image.id) else { return nil }
        return UIImage(contentsOfFile: found.pack.lensImageURL(for: found.photo).path(percentEncoded: false))
    }
}

extension LensSoundKind {
    init(_ kind: PackSound.Kind) {
        self = switch kind {
        case .song: .song
        case .call: .call
        case .sound: .sound
        }
    }
}
