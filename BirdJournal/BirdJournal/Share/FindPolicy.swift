import Album
import Foundation

/// What a sighting sends to the birder's circles as a find (issue #62, spec v2 "Find policy", ADR-0004): pure rules
/// beside the share policy, tested without the server. A find carries the species, Heard or Seen, a city or "a secret
/// spot", the time to the minute, the Legendary and rarity flags and the art reference. Never a coordinate, the note,
/// the caption or a photo of the birder's own: those stay on the phone (the extras of a card shared by hand are #66's).
enum FindPolicy {
    /// The birder's setting, "Share my finds automatically" (on by default).
    enum Sharing: Equatable {
        case automatic
        /// Nothing is published automatically.
        case `private`
    }

    /// The place label of a threatened species (IUCN Vulnerable or worse, or the pack builder's hand list), and of
    /// one whose pack doesn't say: unknown counts as threatened, the safe side, as for captions (#56).
    static let secretSpot = "a secret spot"

    /// What the policy reads about one sighting.
    struct Input {
        var identifier: UUID
        /// The BirdNET label, `Genus species_Common Name`.
        var speciesID: String
        var commonName: String
        var method: SightingMethod
        var confirmedAt: Date
        var rarity: RarityLabel?
        /// The add was the birder's first surviving sighting of the species. Frozen at the add: Legendary passing to
        /// another card later publishes nothing.
        var isLegendary: Bool
        /// From the packs; nil when no pack says.
        var isThreatened: Bool?
        /// The city the phone's reverse geocoding named (`PlaceNames`), nil when unknown or the sighting has no fix.
        var placeName: String?
        /// The species' pack art, as the pack names it: the pack's id and the `pack_art` file.
        var packArt: (packID: String, file: String)?
    }

    /// The find as the API takes it (`PUT /v1/finds/<sighting id>`): every field the server stores, and nothing else.
    struct Find: Codable, Equatable, Sendable {
        struct Art: Codable, Equatable, Sendable {
            /// `pack`: a pack-art thumbnail on the art CDN. Painted art (`painted`) joins finds with #70.
            var kind: String
            var key: String
        }

        var speciesID: String
        var scientificName: String
        var commonName: String
        var method: SightingMethod
        var place: String?
        /// ISO 8601 in UTC, to the minute: `2026-11-01T08:15:00Z`.
        var foundAt: String
        var legendary: Bool
        var rarity: RarityLabel?
        var threatened: Bool
        var art: Art?

        enum CodingKeys: String, CodingKey {
            case speciesID = "species_id"
            case scientificName = "scientific_name"
            case commonName = "common_name"
            case method, place
            case foundAt = "found_at"
            case legendary, rarity, threatened, art
        }

        /// Writes `place`, `rarity` and `art` as null when absent, so a repeated put clears what an earlier one set.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(speciesID, forKey: .speciesID)
            try container.encode(scientificName, forKey: .scientificName)
            try container.encode(commonName, forKey: .commonName)
            try container.encode(method, forKey: .method)
            try container.encode(place, forKey: .place)
            try container.encode(foundAt, forKey: .foundAt)
            try container.encode(legendary, forKey: .legendary)
            try container.encode(rarity, forKey: .rarity)
            try container.encode(threatened, forKey: .threatened)
            try container.encode(art, forKey: .art)
        }
    }

    /// Whether an add publishes a find automatically: only one added while signed in and sharing. A sighting added
    /// while private or signed out never is, not even after the birder signs in or turns sharing back on.
    static func publishesAutomatically(sharing: Sharing, signedIn: Bool) -> Bool {
        signedIn && sharing == .automatic
    }

    /// The find to send, or nil when the birder is private.
    static func find(for input: Input, sharing: Sharing) -> Find? {
        guard sharing == .automatic else { return nil }
        let threatened = input.isThreatened != false
        return Find(
            speciesID: input.speciesID,
            scientificName: Sighting.scientificName(ofLabel: input.speciesID),
            commonName: input.commonName,
            method: input.method,
            place: threatened ? secretSpot : cityLabel(input.placeName),
            foundAt: minute(input.confirmedAt),
            legendary: input.isLegendary,
            rarity: input.rarity,
            threatened: threatened,
            art: input.packArt.map { Find.Art(kind: "pack", key: packArtKey(packID: $0.packID, file: $0.file)) }
        )
    }

    /// The pack-art thumbnail's key on the art CDN, as the pack publish step uploads it (`packbuilder thumbnails`):
    /// `art/sayornis-nigricans.avif` in pack `us-ca-la` is `packs/us-ca-la/sayornis-nigricans.jpg`.
    static func packArtKey(packID: String, file: String) -> String {
        let stem = (file as NSString).lastPathComponent.split(separator: ".", maxSplits: 1).first.map(String.init) ?? file
        return "packs/\(packID)/\(stem).jpg"
    }

    /// The time to the minute, in UTC.
    static func minute(_ date: Date) -> String {
        let seconds = (date.timeIntervalSince1970 / 60).rounded(.down) * 60
        return Date(timeIntervalSince1970: seconds).formatted(.iso8601)
    }

    /// A city name and nothing finer; a label that looks like a coordinate (the album's fallback before a name is
    /// known) is no place at all.
    static func cityLabel(_ name: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        if name.contains("°") || name.range(of: #"\d+[.,]\d{2,}"#, options: .regularExpression) != nil { return nil }
        return String(name.prefix(80))
    }
}
