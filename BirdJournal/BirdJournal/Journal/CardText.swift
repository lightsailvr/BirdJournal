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
        return "\(snapshot.label.title). The BirdNET geomodel rated the chance of \(article(for: commonName)) \(commonName) here in \(when)\(rating), read when you added it. Common, Uncommon, Rare and Exceptional are bands of that chance across the birds of every Featherguild set. Rarity is about the place and the season, not about your patches."
    }

    /// The place on the card: its name when known, else the coordinate; "Place not recorded" without a location, never
    /// a guess.
    static func place(location: Coordinate?, name: String?) -> String {
        guard let location else { return "Place not recorded" }
        return name ?? location.formatted
    }

    /// The original photo kept with the sighting: the birder's own photo (the capture a seen bird was named from, or one
    /// attached from the library), else the glasses photo from the add. Evidence, never art.
    static func originalPhotoPath(_ sighting: Sighting) -> String? {
        sighting.attachedPhotoPaths.first ?? sighting.frameImagePath
    }

    /// Whether the original photo is the glasses' own (from an add on the lens, or the photo a seen bird was named from
    /// when it was taken from the lens), which the journal shows cropped to its middle (`FrameCrop.albumZoom`), and not
    /// one of the birder's own from the phone's camera or the library, shown whole.
    static func originalPhotoIsGlassesFrame(_ sighting: Sighting) -> Bool {
        guard let path = originalPhotoPath(sighting) else { return false }
        return path == sighting.frameImagePath
    }

    /// Under a glasses snapshot on a sighting's page: what the picture is. For an add of a bird that was heard it is the
    /// frame from that moment, wherever the glasses pointed; for a bird seen it is the photo the wearer framed and took
    /// from the lens, at the crop its viewfinder marked.
    static func glassesSnapshotNote(_ sighting: Sighting) -> String {
        sighting.namedByBirder
            ? "Your glasses snapshot: the centre of the photo you took from the lens, as its viewfinder marked it. View original photo shows the whole frame."
            : "Your glasses snapshot: the centre of the camera frame when you added the bird. It may show the surroundings rather than the bird."
    }

    /// The back's evidence line: "Photo attached" only when an original exists.
    static func evidence(_ sighting: Sighting) -> String {
        originalPhotoPath(sighting) == nil ? "No photo attached" : "Photo attached"
    }

    /// How the birder met it, on a sighting's record: "Heard with iPhone microphone"; "Seen, and heard with Ray-Ban Display";
    /// and for a bird they named from a photo (issue #186), which nothing heard, "Seen, photographed with iPhone".
    static func how(_ sighting: Sighting) -> String {
        if sighting.namedByBirder {
            return "Seen, photographed with \(sighting.source == .glasses ? "Ray-Ban Display" : "iPhone")"
        }
        let device = sighting.source == .glasses ? "Ray-Ban Display" : "iPhone microphone"
        return sighting.method == .seen ? "Seen, and heard with \(device)" : "Heard with \(device)"
    }

    /// BirdNET's match score as a sighting's page shows it, "0.82"; nil for a bird the birder named, which has none.
    static func matchScore(_ sighting: Sighting, locale: Locale = .current) -> String? {
        sighting.namedByBirder ? nil : sighting.soundConfidence.formatted(.number.precision(.fractionLength(2)).locale(locale))
    }

    /// What a sighting's page says about how the bird was identified: what the score is and is not, or that there is none.
    static func identification(_ sighting: Sighting) -> String {
        sighting.namedByBirder
            ? "You named this bird from your photo. BirdNET did not hear it, so there is no match score."
            : "BirdNET's best single-window score for this species when it was added, between 0 and 1. It is not a calibrated probability, and it does not make the sighting certain: you did, when you added it."
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
