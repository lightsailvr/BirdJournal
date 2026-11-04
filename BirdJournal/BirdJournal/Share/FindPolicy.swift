import Album
import Foundation

/// What a sighting sends to the birder's circles as a find (issue #62, spec v2 "Find policy", ADR-0004): pure rules
/// beside the share policy, tested without the server. A find carries the species, Heard or Seen, a city or "a secret
/// spot", the time to the minute, whether it sewed a new patch and in which edition (issue #136), the rarity and the art
/// reference. Never a coordinate, the note, the caption or a photo of the birder's own: those stay on the phone, unless
/// the birder shares the card by hand and chooses them (issue #66, `card(for:choices:circleIDs:photoKey:)`).
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
        /// The add sewed its patch: the birder's first surviving sighting of the species in this edition. Frozen at the
        /// add: the sewn date passing to another sighting later publishes nothing.
        var isNewPatch: Bool
        /// The set the sighting is in, by pack id; nil outside every set.
        var edition: String? = nil
        /// From the packs; nil when no pack says.
        var isThreatened: Bool?
        /// The city the phone's reverse geocoding named (`PlaceNames`), nil when unknown or the sighting has no fix.
        var placeName: String?
        /// The species' pack art, as the pack names it: the pack's id and the `pack_art` file.
        var packArt: (packID: String, file: String)?
        /// The patch's painting in this edition, as the pack names it (the `patch` table's file): what a find shows ahead
        /// of pack art.
        var patchArt: (packID: String, file: String)? = nil
        /// The server key of the painting the card shows (scene or approved photo art, issue #70), nil when it shows
        /// pack art: `CardArt.shownPaintingKey`.
        var paintedArtKey: String? = nil
        /// The birder's note; only a card shared by hand carries it, and only when chosen.
        var note: String? = nil
        /// The caption written for the sighting (#56): part of the card face, so a card shared by hand carries it.
        var caption: String? = nil
    }

    /// What the birder chooses on the "A story to share" sheet (issue #66).
    struct Choices: Equatable {
        var includeNote = false
        /// The original photo, faces blurred and metadata stripped (`ArtPhoto.prepare`). Off by default.
        var includeOriginalPhoto = false
        /// The city, or "a secret spot" for a threatened species. Off sends no place at all.
        var includeCity = true
    }

    /// A card shared by hand as the API takes it (`PUT /v1/finds/<sighting id>/card`): the find, the circles chosen
    /// and the extras chosen, nothing else.
    struct Card: Encodable, Equatable, Sendable {
        struct Photo: Encodable, Equatable, Sendable {
            /// The key the upload URL gave: `photos/<sub>/<unguessable>.jpg`.
            var key: String
        }

        var find: Find
        var circleIDs: [String]
        var includePlace: Bool
        var note: String?
        var caption: String?
        var photo: Photo?

        enum CodingKeys: String, CodingKey {
            case find
            case circleIDs = "circle_ids"
            case includePlace = "include_place"
            case note, caption, photo
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(find, forKey: .find)
            try container.encode(circleIDs, forKey: .circleIDs)
            try container.encode(includePlace, forKey: .includePlace)
            try container.encode(note, forKey: .note)
            try container.encode(caption, forKey: .caption)
            try container.encode(photo, forKey: .photo)
        }
    }

    /// The find as the API takes it (`PUT /v1/finds/<sighting id>`): every field the server stores, and nothing else.
    struct Find: Codable, Equatable, Sendable {
        struct Art: Codable, Equatable, Sendable {
            /// `pack`: a thumbnail on the art CDN of the pack's patch or pack art; `painted`: the card's painting (issue #70).
            var kind: String
            var key: String
            /// With a painting only: the pack art the find shows if the server no longer holds the painting (it was
            /// deleted after the phone downloaded it while nothing showed it). Omitted when nil.
            var fallback: Fallback?

            struct Fallback: Codable, Equatable, Sendable {
                var kind: String
                var key: String
            }

            init(kind: String, key: String, fallback: Fallback? = nil) {
                self.kind = kind
                self.key = key
                self.fallback = fallback
            }
        }

        var speciesID: String
        var scientificName: String
        var commonName: String
        var method: SightingMethod
        var place: String?
        /// ISO 8601 in UTC, to the minute: `2026-11-01T08:15:00Z`.
        var foundAt: String
        /// The sighting sewed its patch: what makes a find notable, and what the feed leads with its patch.
        var newPatch: Bool
        /// The set the sighting is in, by pack id; nil outside every set.
        var edition: String?
        var rarity: RarityLabel?
        var threatened: Bool
        var art: Art?

        enum CodingKeys: String, CodingKey {
            case speciesID = "species_id"
            case scientificName = "scientific_name"
            case commonName = "common_name"
            case method, place
            case foundAt = "found_at"
            case newPatch = "new_patch"
            case edition, rarity, threatened, art
        }

        /// Writes `place`, `edition`, `rarity` and `art` as null when absent, so a repeated put clears what an earlier one set.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(speciesID, forKey: .speciesID)
            try container.encode(scientificName, forKey: .scientificName)
            try container.encode(commonName, forKey: .commonName)
            try container.encode(method, forKey: .method)
            try container.encode(place, forKey: .place)
            try container.encode(foundAt, forKey: .foundAt)
            if LegacyFindWire.writesOldForm(encoder) {
                var old = encoder.container(keyedBy: LegacyFindWire.Keys.self)
                try old.encode(newPatch, forKey: .legendary)
            } else {
                try container.encode(newPatch, forKey: .newPatch)
                try container.encode(edition, forKey: .edition)
            }
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
        return payload(for: input)
    }

    private static func payload(for input: Input) -> Find {
        let threatened = input.isThreatened != false
        return Find(
            speciesID: input.speciesID,
            scientificName: Sighting.scientificName(ofLabel: input.speciesID),
            commonName: input.commonName,
            method: input.method,
            place: threatened ? secretSpot : cityLabel(input.placeName),
            foundAt: minute(input.confirmedAt),
            newPatch: input.isNewPatch,
            edition: input.edition,
            rarity: input.rarity,
            threatened: threatened,
            art: art(for: input)
        )
    }

    /// The card's painting when it shows one the server painted, falling back to the patch or pack art; else the patch,
    /// else the pack art.
    private static func art(for input: Input) -> Find.Art? {
        let pack = input.patchArt.map { Find.Art(kind: "pack", key: patchArtKey(packID: $0.packID, file: $0.file)) }
            ?? input.packArt.map { Find.Art(kind: "pack", key: packArtKey(packID: $0.packID, file: $0.file)) }
        guard let painted = input.paintedArtKey else { return pack }
        return Find.Art(kind: "painted", key: painted, fallback: pack.map { Find.Art.Fallback(kind: $0.kind, key: $0.key) })
    }

    /// A card shared by hand (issue #66): the find whatever the sharing setting (it is the only way a private birder's
    /// sighting reaches a circle), with the extras chosen and no others. The city off gives no place, not even "a
    /// secret spot"; the note goes only when chosen and not empty, the photo only when chosen and uploaded
    /// (`photoKey`), and the caption with the card face whenever the sighting has one.
    static func card(for input: Input, choices: Choices, circleIDs: [String], photoKey: String?) -> Card {
        var find = payload(for: input)
        if !choices.includeCity { find.place = nil }
        let note = input.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let caption = input.caption?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Card(
            find: find,
            circleIDs: circleIDs,
            includePlace: choices.includeCity,
            note: choices.includeNote ? note?.nilIfEmpty : nil,
            caption: caption?.nilIfEmpty,
            photo: choices.includeOriginalPhoto ? photoKey.map { Card.Photo(key: $0) } : nil
        )
    }

    /// The place a shared card shows, on its face and in the circles: the find's rule (a city, or "a secret spot" for
    /// a threatened or unrated species), or none when the city is off.
    static func sharedPlace(for input: Input, choices: Choices) -> String? {
        guard choices.includeCity else { return nil }
        return payload(for: input).place
    }

    /// The pack-art thumbnail's key on the art CDN, as the pack publish step uploads it (`packbuilder thumbnails`):
    /// `art/sayornis-nigricans.avif` in pack `us-ca-la` is `packs/us-ca-la/sayornis-nigricans.jpg`.
    static func packArtKey(packID: String, file: String) -> String {
        // The last extension only, as the builder's `PurePosixPath.stem` does.
        let stem = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
        return "packs/\(packID)/\(stem).jpg"
    }

    /// The patch thumbnail's key on the art CDN, as `packbuilder thumbnails` writes it, cut out on transparency:
    /// `patch/sayornis-nigricans.avif` in pack `us-ca-la` is `packs/us-ca-la/patch/sayornis-nigricans.png`. Under `packs/`
    /// with the `pack` kind, so a server from before #136 takes it too.
    static func patchArtKey(packID: String, file: String) -> String {
        let stem = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
        return "packs/\(packID)/patch/\(stem).png"
    }

    /// The time to the minute, in UTC.
    static func minute(_ date: Date) -> String {
        let seconds = (date.timeIntervalSince1970 / 60).rounded(.down) * 60
        return Date(timeIntervalSince1970: seconds).formatted(.iso8601)
    }

    /// A city name and nothing finer; a label that looks like a coordinate (the album's fallback before a name is
    /// known) is no place at all. The same rule the server refuses places by (`backend/.../finds.py`, `_COORDINATE`):
    /// a number with two or more decimals, a degree sign, or minutes or seconds after a number.
    static func cityLabel(_ name: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        if name.contains("°") || name.range(of: #"\d+[.,]\d{2,}|\d\s*['′″"]"#, options: .regularExpression) != nil { return nil }
        return String(name.prefix(80))
    }
}
