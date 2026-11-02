import Album
import Foundation
import Testing
@testable import BirdJournal

// Issue #66: a card shared by hand carries the extras the birder chose and no others: the note and the original
// photo only when chosen, the city on by default and no place at all when off, the caption with the card face, and
// the find whatever the sharing setting.
@Suite("Shared card policy")
struct SharedCardPolicyTests {
    static func input(note: String? = "On the fence by the creek", caption: String? = "A small black flame at the water's edge", isThreatened: Bool? = false, placeName: String? = "Pasadena") -> FindPolicy.Input {
        var input = FindPolicyTests.input(isThreatened: isThreatened, placeName: placeName)
        input.note = note
        input.caption = caption
        return input
    }

    static let photoKey = "photos/fake-sub/abcdefghijklmnopqrstuvwx.jpg"

    @Test("by default: the city and the caption, no note and no photo")
    func defaults() {
        let card = FindPolicy.card(for: Self.input(), choices: .init(), circleIDs: ["c1"], photoKey: Self.photoKey)
        #expect(card.find.place == "Pasadena")
        #expect(card.includePlace)
        #expect(card.caption == "A small black flame at the water's edge")
        #expect(card.note == nil, "the note goes only when chosen")
        #expect(card.photo == nil, "the original photo is off by default")
        #expect(card.circleIDs == ["c1"])
    }

    @Test("the note and the photo appear only when chosen")
    func extrasWhenChosen() {
        let chosen = FindPolicy.Choices(includeNote: true, includeOriginalPhoto: true, includeCity: true)
        let card = FindPolicy.card(for: Self.input(), choices: chosen, circleIDs: ["c1", "c2"], photoKey: Self.photoKey)
        #expect(card.note == "On the fence by the creek")
        #expect(card.photo == .init(key: Self.photoKey))
        // Chosen but nothing to send: an empty note, no upload.
        let empty = FindPolicy.card(for: Self.input(note: "   "), choices: chosen, circleIDs: ["c1"], photoKey: nil)
        #expect(empty.note == nil)
        #expect(empty.photo == nil)
    }

    @Test("the city off sends no place, not even a secret spot")
    func cityOff() {
        let off = FindPolicy.Choices(includeCity: false)
        #expect(FindPolicy.card(for: Self.input(), choices: off, circleIDs: ["c1"], photoKey: nil).find.place == nil)
        let threatened = FindPolicy.card(for: Self.input(isThreatened: true), choices: off, circleIDs: ["c1"], photoKey: nil)
        #expect(threatened.find.place == nil)
        #expect(!threatened.includePlace)
        #expect(FindPolicy.sharedPlace(for: Self.input(), choices: off) == nil)
    }

    @Test("the city on keeps the find's rules: a secret spot for a threatened species, never a coordinate")
    func cityOnKeepsTheRules() {
        #expect(FindPolicy.card(for: Self.input(isThreatened: true), choices: .init(), circleIDs: ["c1"], photoKey: nil).find.place == "a secret spot")
        #expect(FindPolicy.card(for: Self.input(placeName: "34.1478, -118.1445"), choices: .init(), circleIDs: ["c1"], photoKey: nil).find.place == nil)
        #expect(FindPolicy.sharedPlace(for: Self.input(), choices: .init()) == "Pasadena")
    }

    @Test("an automatic find never carries the extras, whatever the input has")
    func automaticFindHasNoExtras() throws {
        let find = try #require(FindPolicy.find(for: Self.input(), sharing: .automatic))
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(find)) as? [String: Any]
        #expect(json?["note"] == nil)
        #expect(json?["caption"] == nil)
    }

    @Test("the card is the find with exactly the API's keys, and never a coordinate")
    func encodedKeys() throws {
        let card = FindPolicy.card(for: Self.input(), choices: .init(includeNote: true, includeOriginalPhoto: true), circleIDs: ["c1"], photoKey: Self.photoKey)
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(card)) as? [String: Any])
        #expect(Set(json.keys) == ["find", "circle_ids", "include_place", "note", "caption", "photo"])
        let text = String(decoding: try JSONEncoder().encode(card), as: UTF8.self)
        #expect(!text.contains("latitude") && !text.contains("34."))
    }
}
