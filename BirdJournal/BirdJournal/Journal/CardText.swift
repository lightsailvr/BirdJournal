import Album
import Foundation

/// What a sighting's card says about it (issue #52): the rarity and its explanation, the place and the original photo.
/// Every missing piece has a plain fallback, and nothing is guessed: no place without a location and no rarity without a
/// reading.
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
        return "\(snapshot.label.title). The BirdNET geomodel rated the chance of \(article(for: commonName)) \(commonName) here in \(when)\(rating), read when you added it. Common, Uncommon, Rare and Exceptional are bands of that chance across the birds of the Featherguild packs. Rarity is about the place and the season, not about your patches."
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

    static func article(for name: String) -> String {
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
