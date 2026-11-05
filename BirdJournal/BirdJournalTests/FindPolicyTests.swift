import Album
import Foundation
import Testing
@testable import BirdJournal

// Issue #62: what an add sends to the birder's circles. Automatic versus private, the secret spot for a threatened
// species (and one no pack rates), never a coordinate, and the new-patch and rarity flags. The extras of a card shared
// by hand come with #66.
@Suite("Find policy")
struct FindPolicyTests {
    static let identifier = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
    /// 2026-09-21 14:13:20 UTC, with 20 seconds past the minute.
    static let confirmedAt = Date(timeIntervalSince1970: 1_790_000_000)

    static func input(
        isThreatened: Bool? = false, placeName: String? = "Pasadena", isNewPatch: Bool = false, rarity: RarityLabel? = .common,
        method: SightingMethod = .heard, patchArt: (packID: String, file: String)? = ("us-ca-la", "patch/sayornis-nigricans.avif")
    ) -> FindPolicy.Input {
        FindPolicy.Input(
            identifier: identifier, speciesID: "Sayornis nigricans_Black Phoebe", commonName: "Black Phoebe", method: method,
            confirmedAt: confirmedAt, rarity: rarity, isNewPatch: isNewPatch, isThreatened: isThreatened,
            placeName: placeName, patchArt: patchArt
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

    @Test("an automatic find carries the species, Heard or Seen, the city, the minute, the flags and the patch's art")
    func automaticFind() throws {
        let find = try #require(FindPolicy.find(for: Self.input(isNewPatch: true, rarity: .rare, method: .seen), sharing: .automatic))
        #expect(find == FindPolicy.Find(
            speciesID: "Sayornis nigricans_Black Phoebe", scientificName: "Sayornis nigricans", commonName: "Black Phoebe",
            method: .seen, place: "Pasadena", foundAt: "2026-09-21T14:13:00Z", newPatch: true, edition: nil, rarity: .rare,
            threatened: false, art: .init(kind: "pack", key: "packs/us-ca-la/patch/sayornis-nigricans.png")
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
        for label in ["34.1365, -118.2942", "34.13650° N, 118.29420° W", "34 8' N", "  "] {
            let find = try #require(FindPolicy.find(for: Self.input(placeName: label), sharing: .automatic))
            #expect(find.place == nil, "\(label)")
        }
        let find = try #require(FindPolicy.find(for: Self.input(), sharing: .automatic))
        let json = String(decoding: try JSONEncoder().encode(find), as: UTF8.self)
        for word in ["latitude", "longitude", "location", "coordinate", "accuracy", "note", "caption", "frame", "photo"] {
            #expect(!json.contains(word), "\(word) in \(json)")
        }
        let keys = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]).keys.sorted()
        #expect(keys == ["art", "common_name", "edition", "found_at", "method", "new_patch", "place", "rarity", "scientific_name", "species_id", "threatened"])
    }

    @Test("a find says whether it sewed a new patch and in which edition, and shows the patch's art")
    func newPatchAndEdition() throws {
        var input = Self.input(isNewPatch: true)
        input.edition = "us-ca-la"
        input.patchArt = (packID: "us-ca-la", file: "patch/sayornis-nigricans.avif")
        let find = try #require(FindPolicy.find(for: input, sharing: .automatic))
        #expect(find.newPatch && find.edition == "us-ca-la")
        #expect(find.art == FindPolicy.Find.Art(kind: "pack", key: "packs/us-ca-la/patch/sayornis-nigricans.png"))

        // Outside every set: no edition, written as null so a repeated put clears it. A pack without patches sends no art,
        // since the watercolours are retired (#137): the viewer draws the edition's blank.
        let plain = try #require(FindPolicy.find(for: Self.input(isNewPatch: false, patchArt: nil), sharing: .automatic))
        #expect(plain.art == nil)
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any])
        #expect(json["edition"] is NSNull)
        #expect(json["new_patch"] as? Bool == false)
        #expect(json["legendary"] == nil, "nothing writes the old name but the seam")
    }

    @Test("the patch's key is what the art CDN and the deployed server take")
    func patchArtKey() {
        let key = FindPolicy.patchArtKey(packID: "us-ca-la", file: "patch/sayornis-nigricans.avif")
        #expect(key == "packs/us-ca-la/patch/sayornis-nigricans.png")
        // backend/.../finds.py, `_ART_KEY`.
        #expect(key.range(of: #"^(packs|art)/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*\.(jpg|jpeg|png|webp)$"#, options: .regularExpression) != nil)
    }

    @Test("the time goes to the minute in UTC, without the seconds")
    func minute() {
        #expect(FindPolicy.minute(Self.confirmedAt) == "2026-09-21T14:13:00Z")
        #expect(FindPolicy.minute(Date(timeIntervalSince1970: 1_790_000_039.9)) == "2026-09-21T14:13:00Z")
    }

    @Test("rarity and art may be absent, and say so as null")
    func absentFields() throws {
        let find = try #require(FindPolicy.find(for: Self.input(rarity: nil, patchArt: nil), sharing: .automatic))
        #expect(find.rarity == nil && find.art == nil && !find.newPatch)
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(find)) as? [String: Any])
        #expect(object["rarity"] is NSNull)
        #expect(object["art"] is NSNull)
    }

    @Test("the patch's key takes off the last extension only")
    func patchArtKeyStem() {
        #expect(FindPolicy.patchArtKey(packID: "us-ca-la", file: "patch/x.v2.avif") == "packs/us-ca-la/patch/x.v2.png")
    }

    @Test("a find's art is only ever a kind and a key: no painting, no fallback (#137)")
    func artKeys() throws {
        let find = try #require(FindPolicy.find(for: Self.input(), sharing: .automatic))
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(find)) as? [String: Any])
        #expect(Set(try #require(json["art"] as? [String: Any]).keys) == ["kind", "key"])
    }
}
