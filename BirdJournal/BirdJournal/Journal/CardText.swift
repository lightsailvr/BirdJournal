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
        return "\(snapshot.label.title). The BirdNET geomodel rated the chance of \(article(for: commonName)) \(commonName) here in \(when)\(rating), read when you added it. Common, Uncommon, Rare and Exceptional are bands of that chance across the birds of the Featherguild packs. Rarity is about the place and the season, not whether the card is Legendary."
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

    /// A card's art (issue #57), in this order: approved photo art, then ready scene art unless the birder chose "Use
    /// pack art", then the pack's art, then the pack's reference photo, then none (a typographic face). The glasses
    /// photo is the sighting's evidence, never its art.
    enum Art: Equatable {
        /// The birder's photo, painted and approved; relative to the `FrameStore`.
        case photoArt(path: String)
        /// The glasses photo from the add, painted; relative to the `FrameStore`.
        case sceneArt(path: String)
        /// The pack's painting of the species, with the credit of the photo it was painted from (nil when it was
        /// painted from text, for a species with no open-license photo).
        case packArt(URL, credit: String?)
        case referencePhoto(URL, credit: String)
        case none

        /// `packArt` is the pack art for the card's set (`PackLibrary.packArt`) and `reference` the pack's first photo
        /// of the species, each nil when no pack has one.
        init(sighting: Sighting, packArt: (url: URL, credit: String?)?, reference: (url: URL, credit: String)?) {
            let art = sighting.art
            if let photo = art.photo, photo.state == .ready, let path = photo.path {
                self = .photoArt(path: path)
            } else if let scene = art.scene, scene.state == .ready, let path = scene.path, !art.prefersPackArt {
                self = .sceneArt(path: path)
            } else if let packArt {
                self = .packArt(packArt.url, credit: packArt.credit)
            } else if let reference {
                self = .referencePhoto(reference.url, credit: reference.credit)
            } else {
                self = .none
            }
        }

        /// The label under the art on the front: what kind of picture it is, so art is never taken for evidence.
        var label: String {
            switch self {
            case .photoArt: "AI-embellished from your photo"
            case .sceneArt, .packArt: "AI illustration"
            case .referencePhoto: "Reference photo"
            case .none: "No art yet"
            }
        }

        /// The back's provenance line, naming the model (ADR-0007).
        var provenance: String {
            switch self {
            case .photoArt: "Your own photo, AI-embellished by FLUX.3 Image Klein and approved by you. The original is kept as evidence."
            case .sceneArt: "An AI illustration painted by FLUX.3 Image Klein into your glasses photo from this sighting. Not a photo."
            case .packArt(_, let credit?): "An AI illustration from your bird pack, painted by FLUX.3 Image Klein from a reference photo (\(credit)). It shows the species, not your bird."
            case .packArt(_, nil): "An AI illustration from your bird pack, painted by FLUX.3 Image Klein from a description of the species. It shows the species, not your bird."
            case .referencePhoto(_, let credit): "A reference photo from your bird pack, not your bird. \(credit)."
            case .none: "No art yet: no pack art and no pack photo of this bird."
            }
        }
    }

    /// What the card's front says about scene art under way (issue #68): the encounter is safe while the painting
    /// waits, even for days with the painting machine off; a failure says so plainly. Nil otherwise.
    static func sceneArtLine(_ status: CardArt.SceneStatus) -> String? {
        switch status {
        case .pending: "Your encounter is saved. Artwork is on its way."
        case .failed: "The artwork couldn't be painted this time."
        case .none, .ready: nil
        }
    }

    /// What the card says about photo art under way (issue #69); nil otherwise.
    static func photoArtLine(_ status: CardArt.PhotoStatus) -> String? {
        switch status {
        case .pending: "Your photo is being painted. Your encounter is saved."
        case .failed: "Your photo couldn't be painted this time."
        case .preview: "Your photo art is ready to review."
        case .none, .approved: nil
        }
    }

    /// "N left today": the public launch's daily paintings on request (issue #69); nil without a limit.
    static func allowanceLine(_ allowance: ArtAllowance?) -> String? {
        guard let allowance, allowance.daily != nil, let left = allowance.left else { return nil }
        return "\(left) left today"
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
