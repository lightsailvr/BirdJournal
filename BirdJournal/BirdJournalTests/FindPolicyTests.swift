import Album
import Foundation
import Testing
@testable import BirdJournal

// Issue #62: what an add sends to the birder's circles. Automatic versus private, the secret spot for a threatened
// species (and one no pack rates), never a coordinate, and the Legendary and rarity flags. The extras of a card shared
// by hand come with #66.
@Suite("Find policy")
struct FindPolicyTests {
    static let identifier = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
    /// 2026-09-21 14:13:20 UTC, with 20 seconds past the minute.
    static let confirmedAt = Date(timeIntervalSince1970: 1_790_000_000)

    static func input(
        isThreatened: Bool? = false, placeName: String? = "Pasadena", isLegendary: Bool = false, rarity: RarityLabel? = .common,
        method: SightingMethod = .heard, packArt: (packID: String, file: String)? = ("us-ca-la", "art/sayornis-nigricans.avif")
    ) -> FindPolicy.Input {
        FindPolicy.Input(
            identifier: identifier, speciesID: "Sayornis nigricans_Black Phoebe", commonName: "Black Phoebe", method: method,
            confirmedAt: confirmedAt, rarity: rarity, isLegendary: isLegendary, isThreatened: isThreatened,
            placeName: placeName, packArt: packArt
        )
    }

    @Test("an add publishes only while signed in and sharing")
    func automaticOrPrivate() {
        #expect(FindPolicy.publishesAutomatically(sharing: .automatic, signedIn: true))
        #expect(!FindPolicy.publishesAutomatically(sharing: .private, signedIn: true))
        #expect(!FindPolicy.publishesAutomatically(sharing: .automatic, signedIn: false))
        #expect(!FindPolicy.publishesAutomatically(sharing: .private, signedIn: false))
        #expect(FindPolicy.find(for: Self.input(), sharing: .private) == nil, "private sends nothing")
    }

    @Test("an automatic find carries the species, Heard or Seen, the city, the minute, the flags and the pack art")
    func automaticFind() throws {
        let find = try #require(FindPolicy.find(for: Self.input(isLegendary: true, rarity: .rare, method: .seen), sharing: .automatic))
        #expect(find == FindPolicy.Find(
            speciesID: "Sayornis nigricans_Black Phoebe", scientificName: "Sayornis nigricans", commonName: "Black Phoebe",
            method: .seen, place: "Pasadena", foundAt: "2026-09-21T14:13:00Z", legendary: true, rarity: .rare,
            threatened: false, art: .init(kind: "pack", key: "packs/us-ca-la/sayornis-nigricans.jpg")
        ))
    }

    @Test("a threatened species is at a secret spot, and so is one whose pack doesn't say")
    func secretSpot() throws {
        for threatened in [true, nil] as [Bool?] {
            let find = try #require(FindPolicy.find(for: Self.input(isThreatened: threatened, placeName: "Palos Verdes Estates"), sharing: .automatic))
            #expect(find.place == "a secret spot")
            #expect(find.threatened)
        }
        let noFix = try #require(FindPolicy.find(for: Self.input(isThreatened: true, placeName: nil), sharing: .automatic))
        #expect(noFix.place == "a secret spot")
        let safe = try #require(FindPolicy.find(for: Self.input(isThreatened: false, placeName: nil), sharing: .automatic))
        #expect(safe.place == nil, "no fix, no place")
        #expect(!safe.threatened)
    }

    @Test("a find never carries a coordinate, even when the place label is one")
    func neverACoordinate() throws {
        // Before a name is known the album shows the coordinate as the place; that is no city.
        for label in ["34.1365, -118.2942", "34.13650° N, 118.29420° W", "  "] {
            let find = try #require(FindPolicy.find(for: Self.input(placeName: label), sharing: .automatic))
            #expect(find.place == nil, "\(label)")
        }
        let find = try #require(FindPolicy.find(for: Self.input(), sharing: .automatic))
        let json = String(decoding: try JSONEncoder().encode(find), as: UTF8.self)
        for word in ["latitude", "longitude", "location", "coordinate", "accuracy", "note", "caption", "frame", "photo"] {
            #expect(!json.contains(word), "\(word) in \(json)")
        }
        let keys = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]).keys.sorted()
        #expect(keys == ["art", "common_name", "found_at", "legendary", "method", "place", "rarity", "scientific_name", "species_id", "threatened"])
    }

    @Test("the time goes to the minute in UTC, without the seconds")
    func minute() {
        #expect(FindPolicy.minute(Self.confirmedAt) == "2026-09-21T14:13:00Z")
        #expect(FindPolicy.minute(Date(timeIntervalSince1970: 1_790_000_039.9)) == "2026-09-21T14:13:00Z")
    }

    @Test("rarity and art may be absent, and say so as null")
    func absentFields() throws {
        let find = try #require(FindPolicy.find(for: Self.input(rarity: nil, packArt: nil), sharing: .automatic))
        #expect(find.rarity == nil && find.art == nil && !find.legendary)
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(find)) as? [String: Any])
        #expect(object["rarity"] is NSNull)
        #expect(object["art"] is NSNull)
    }

    @Test("the pack-art key is the thumbnail the pack publish step uploads")
    func packArtKey() {
        #expect(FindPolicy.packArtKey(packID: "us-ca-la", file: "art/sayornis-nigricans.avif") == "packs/us-ca-la/sayornis-nigricans.jpg")
        #expect(FindPolicy.packArtKey(packID: "us-ca-sd", file: "art/calypte-anna.png") == "packs/us-ca-sd/calypte-anna.jpg")
    }
}
