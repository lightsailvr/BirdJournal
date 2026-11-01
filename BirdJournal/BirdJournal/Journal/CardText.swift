import Album
import Foundation

/// What a card says about its sighting (issue #52): the rarity on the front and its explanation on the back, the
/// place, the original photo and what the art is. Every missing piece has a plain fallback, and nothing is guessed:
/// no place without a location, no rarity without a reading, and a reference photo never passed off as the bird.
enum CardText {
    static let rarityUnavailable = "Rarity unavailable for this place and season"

    /// BirdNET's week of its 48-week year as part of a month: "early October", "mid October" or "late October".
    static func season(week: Int, locale: Locale = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let month = calendar.standaloneMonthSymbols[(min(max(week, 1), 48) - 1) / 4]
        let part = switch (week - 1) % 4 {
        case 0: "early"
        case 3: "late"
        default: "mid"
        }
        return "\(part) \(month)"
    }

    /// The front's rarity: "Rare here in late October", or that there is none.
    static func rarityLine(_ snapshot: RaritySnapshot?, locale: Locale = .current) -> String {
        guard let snapshot else { return rarityUnavailable }
        return "\(snapshot.label.title) here in \(season(week: snapshot.week, locale: locale))"
    }

    /// The back's explanation: where the label came from, or why there is none.
    static func rarityExplanation(_ snapshot: RaritySnapshot?, commonName: String, hasLocation: Bool, locale: Locale = .current) -> String {
        guard let snapshot else {
            return hasLocation
                ? "\(rarityUnavailable). The BirdNET geomodel has no reading for this bird here."
                : "\(rarityUnavailable). No location was saved with this sighting, and rarity is never guessed."
        }
        let when = season(week: snapshot.week, locale: locale)
        let rating = snapshot.occurrence.map { " at \($0.formatted(.number.precision(.fractionLength(2)).locale(locale))) on a scale of 0 to 1" } ?? ""
        return "\(snapshot.label.title). The BirdNET geomodel rated the chance of \(article(for: commonName)) \(commonName) here in \(when)\(rating), read when you added it. Common, Uncommon, Rare and Exceptional are bands of that chance across the birds of the Bird Journal packs. Rarity is about the place and the season, not whether the card is Legendary."
    }

    /// The place on the card: its name when known, else the coordinate; "Place not recorded" without a location, never
    /// a guess.
    static func place(location: Coordinate?, name: String?) -> String {
        guard let location else { return "Place not recorded" }
        return name ?? location.formatted
    }

    /// The original photo kept with the sighting: the birder's own attached photo, else the glasses photo from the add.
    /// Evidence, never art.
    static func originalPhotoPath(_ sighting: Sighting) -> String? {
        sighting.attachedPhotoPaths.first ?? sighting.frameImagePath
    }

    /// The back's evidence line: "Photo attached" only when an original exists.
    static func evidence(_ sighting: Sighting) -> String {
        originalPhotoPath(sighting) == nil ? "No photo attached" : "Photo attached"
    }

    /// A card's art until pack art arrives: the glasses photo, else the pack's reference photo, else none.
    enum Art: Equatable {
        case glassesPhoto(String)
        case referencePhoto(credit: String)
        case none

        /// `referenceCredit` is the credit of the pack's first photo of the species, nil when no pack has one.
        init(sighting: Sighting, referenceCredit: String?) {
            if let path = sighting.frameImagePath {
                self = .glassesPhoto(path)
            } else if let referenceCredit {
                self = .referencePhoto(credit: referenceCredit)
            } else {
                self = .none
            }
        }

        /// The label under the art on the front.
        var label: String {
            switch self {
            case .glassesPhoto: "Your glasses photo"
            case .referencePhoto: "Reference photo"
            case .none: "No art yet"
            }
        }

        /// The back's provenance line.
        var provenance: String {
            switch self {
            case .glassesPhoto: "Your glasses photo from this sighting, at the journal's crop. A photo, not a painting."
            case .referencePhoto(let credit): "A reference photo from your bird pack, not your bird. \(credit)."
            case .none: "No art yet: no photo of this sighting, and no pack photo of this bird."
            }
        }
    }

    private static func article(for name: String) -> String {
        name.first.map { "AEIOU".contains($0) } == true ? "an" : "a"
    }
}

extension RarityLabel {
    /// "Common", "Uncommon", "Rare" or "Exceptional".
    var title: String {
        switch self {
        case .common: "Common"
        case .uncommon: "Uncommon"
        case .rare: "Rare"
        case .exceptional: "Exceptional"
        }
    }
}
