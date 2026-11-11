import Album
import Foundation
import SwiftData

// Issue #190 (of #185): "Change bird". A sighting the birder named can be given another bird from its page; the naming
// sheet opens again on it, and `JournalEdits.changeBird` writes the change. A heard sighting has no such button: BirdNET
// named its bird.

/// A sighting the birder named, as "Change bird" holds it: a value and not the model, so the sheet is not left holding a
/// record that has since been removed. It says what the sheet shows of the sighting (its bird now, its photo, when and
/// where) and what the suggestions are read from (the place, and the week of the time).
nonisolated struct NamedSighting: Identifiable, Hashable, Sendable {
    /// The sighting's stable identifier.
    let id: UUID
    /// The label the sighting is written under now.
    let speciesID: String
    /// Its bird's name now, as its page shows it.
    let commonName: String
    /// When the photo was taken: the sighting's time.
    let seenAt: Date
    /// Where the birder was; nil when no place was known.
    let location: Coordinate?
    /// The photo it was named from, relative to the `FrameStore`; nil once the birder has removed it.
    let photoPath: String?

    /// The scientific name of its bird now.
    var scientificName: String { Sighting.scientificName(ofLabel: speciesID) }
}

extension NamedSighting {
    /// - Parameter commonName: the bird's name as the phone shows it: a field guide's where one describes the bird.
    init(_ sighting: Sighting, commonName: String) {
        self.init(id: sighting.identifier, speciesID: sighting.speciesID, commonName: commonName, seenAt: sighting.confirmedAt, location: sighting.location, photoPath: sighting.attachedPhotoPaths.first)
    }
}

/// What the naming sheet is open on: a photo waiting for its name, or a sighting whose bird is being changed.
nonisolated enum NamingSubject: Hashable, Sendable {
    case unnamed(UnnamedSighting)
    case named(NamedSighting)

    /// Where the photo was taken: where a bird's patch would go, and where the geomodel is read.
    var location: Coordinate? {
        switch self {
        case .unnamed(let unnamed): unnamed.location
        case .named(let sighting): sighting.location
        }
    }

    /// When the photo was taken: the week the geomodel is read for.
    var takenAt: Date {
        switch self {
        case .unnamed(let unnamed): unnamed.takenAt
        case .named(let sighting): sighting.seenAt
        }
    }

    /// The photo, relative to the `FrameStore`; nil for a sighting whose photo the birder has removed.
    var photoPath: String? {
        switch self {
        case .unnamed(let unnamed): unnamed.photoPath
        case .named(let sighting): sighting.photoPath
        }
    }

    /// The sighting whose bird is being changed; nil while a photo is being named.
    var changing: NamedSighting? {
        if case .named(let sighting) = self { sighting } else { nil }
    }
}

/// What "Change bird" says, apart from the views so the words are tested without drawing.
enum ChangeBirdText {
    /// The button on the sighting's page, and the sheet's title.
    static let title = "Change bird"
    /// What VoiceOver adds to the button on the sighting's page.
    static let hint = "Chooses another bird for this sighting"

    /// The current bird's line among the results, in parts: it is marked, so it isn't taken for a choice.
    static func currentStatus(placement: CardPlacement) -> [String] {
        [placement.setName, "This sighting's bird"]
    }

    /// The pinned button: "Change and sew patch" when the chosen bird has no patch where the sighting is, else "Change
    /// bird"; that too before another bird is chosen, when it can't be pressed.
    static func confirmTitle(seenHere: Int?) -> String {
        seenHere == 0 ? "Change and sew patch" : "Change bird"
    }

    /// The line under the button: what to do, or what the change would do. The chosen bird's patch gains the sighting or
    /// is sewn, as for an add; and when the sighting is the last of its bird's patch, that patch goes, which is said
    /// before it happens, as a removal's dialog does.
    /// - Parameters:
    ///   - current: the sighting's bird now.
    ///   - chosen: the bird chosen; nil before one is.
    ///   - isCurrent: the chosen bird is the one the sighting already is.
    ///   - seenHere: the chosen bird's sightings where this one is, without this one.
    ///   - unpicks: the placement of the current bird's patch when this is its last sighting, else nil.
    static func note(current: String, chosen: String?, isCurrent: Bool, seenHere: Int, unpicks: CardPlacement?) -> String {
        guard let chosen else { return "Choose the bird you saw." }
        if isCurrent { return "This sighting is already named \(chosen)." }
        let gains = seenHere == 0 ? "\(chosen), new to you here." : "\(chosen), seen \(CardCollection.Patch.times(seenHere)) here."
        guard let unpicks else { return gains }
        let place = unpicks.setID == nil ? "outside every set" : "in \(unpicks.setName)"
        return "\(gains) Your \(current) patch \(place) will be unpicked."
    }

    /// Under the button when the change could not be written.
    static let failed = "The bird couldn't be changed. Your sighting is as it was. Try again."
}

extension ListeningCoordinator {
    /// The birds heard on the run `sighting` was seen on, while that run is under way or under review; none for a sighting
    /// from an earlier run: what this run hears says nothing about it.
    func heardScientificNames(for sighting: NamedSighting) -> [String] {
        sightings.seen.contains { $0.identifier == sighting.id } ? heardScientificNames : []
    }
}
