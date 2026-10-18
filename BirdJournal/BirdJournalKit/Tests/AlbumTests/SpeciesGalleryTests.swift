import Foundation
import Testing
@testable import Album

// Issue #53: one species' cards as a gallery, with a place filter, a sort, and each card's position within the
// filtered order. Pure over value snapshots, so these tests build the cards by hand.
@Suite("Species gallery")
struct SpeciesGalleryTests {
    static let start = Date(timeIntervalSince1970: 1_800_000_000)
    static let losAngeles = "Los Angeles, CA"
    static let sanDiego = "San Diego, CA"

    static func card(_ id: Int, hours: Double, at place: String?) -> SpeciesGallery.Card {
        SpeciesGallery.Card(identifier: CardCollectionTests.uuid(id), confirmedAt: start.addingTimeInterval(hours * 3600), place: place)
    }

    static func ids(_ cards: [SpeciesGallery.Card]) -> [Int] {
        cards.map { Int($0.identifier.uuidString.suffix(12))! }
    }

    /// Five cards over two places and one without a place, in no particular order.
    static let cards = [
        card(1, hours: 10, at: losAngeles),
        card(2, hours: 50, at: sanDiego),
        card(3, hours: 30, at: losAngeles),
        card(4, hours: 20, at: nil),
        card(5, hours: 40, at: sanDiego),
        card(6, hours: 60, at: losAngeles),
    ]

    @Test("the header names the cards, the places and the first discovery")
    func header() {
        let gallery = SpeciesGallery(Self.cards)

        #expect(gallery.title(commonName: "House Finch") == "House Finch · 6 cards · 2 places")
        #expect(gallery.firstDiscovery == Self.start.addingTimeInterval(10 * 3600))
        #expect(SpeciesGallery([Self.card(1, hours: 0, at: Self.sanDiego)]).title(commonName: "House Finch") == "House Finch · 1 card · 1 place")
        #expect(SpeciesGallery([Self.card(1, hours: 0, at: nil)]).title(commonName: "House Finch") == "House Finch · 1 card", "no place recorded, none counted")
        #expect(SpeciesGallery([]).firstDiscovery == nil)
    }

    @Test("a place filter shows that place's cards and counts them against the total")
    func placeFilter() {
        let gallery = SpeciesGallery(Self.cards, filter: .named(Self.losAngeles))

        #expect(Self.ids(gallery.shown) == [6, 3, 1], "newest first by default")
        #expect(gallery.shownText == "3 of 6 cards")
        #expect(gallery.cardCount == 6, "the header still counts every card")
        #expect(Self.ids(SpeciesGallery(Self.cards, filter: .notRecorded).shown) == [4])
        #expect(SpeciesGallery(Self.cards).shownText == "6 cards", "unfiltered, just the total")
    }

    @Test("the place picker lists each recorded place with its count, alphabetically, then the cards with no place")
    func pickerPlaces() {
        let places = SpeciesGallery(Self.cards).places

        #expect(places.map(\.filter) == [.named(Self.losAngeles), .named(Self.sanDiego), .notRecorded])
        #expect(places.map(\.title) == [Self.losAngeles, Self.sanDiego, "Place not recorded"])
        #expect(places.map(\.count) == [3, 2, 1])
        #expect(SpeciesGallery.PlaceFilter.all.title == "All places")
        #expect(SpeciesGallery.PlaceFilter.named(Self.sanDiego).title == Self.sanDiego)
        #expect(!SpeciesGallery([Self.card(1, hours: 0, at: Self.sanDiego)]).places.contains { $0.filter == .notRecorded })
    }

    @Test("a filter that matches nothing shows no cards and says so")
    func filterWithNoMatches() {
        let gallery = SpeciesGallery(Self.cards, filter: .named("Pasadena, CA"))

        #expect(gallery.shown.isEmpty)
        #expect(gallery.isFiltered)
        #expect(gallery.shownText == "0 of 6 cards")
        #expect(!SpeciesGallery(Self.cards).isFiltered)
    }

    @Test("the sort orders the filtered cards newest first, oldest first, or by place with no place last")
    func sort() {
        #expect(Self.ids(SpeciesGallery(Self.cards, sort: .newest).shown) == [6, 2, 5, 3, 4, 1])
        #expect(Self.ids(SpeciesGallery(Self.cards, sort: .oldest).shown) == [1, 4, 3, 5, 2, 6])
        #expect(Self.ids(SpeciesGallery(Self.cards, sort: .place).shown) == [6, 3, 1, 2, 5, 4], "by place, newest first within one")
        #expect(Self.ids(SpeciesGallery(Self.cards, filter: .named(Self.sanDiego), sort: .oldest).shown) == [5, 2])
        #expect(SpeciesGallery.Sort.allCases.map(\.title) == ["Newest first", "Oldest first", "By place"])
    }

    @Test("two cards at the same moment keep one order both ways")
    func sortTies() {
        let twins = [Self.card(7, hours: 5, at: Self.sanDiego), Self.card(8, hours: 5, at: Self.sanDiego)]
        #expect(Self.ids(SpeciesGallery(twins, sort: .newest).shown) == [8, 7])
        #expect(Self.ids(SpeciesGallery(twins, sort: .oldest).shown) == [7, 8])
    }

    @Test("a card's position, previous and next follow the filtered, sorted order and stop at its ends")
    func positionWithinFilter() throws {
        let gallery = SpeciesGallery(Self.cards, filter: .named(Self.losAngeles), sort: .oldest)
        let first = CardCollectionTests.uuid(1), middle = CardCollectionTests.uuid(3), last = CardCollectionTests.uuid(6)

        let position = try #require(gallery.position(of: middle))
        #expect(position.index == 2)
        #expect(position.count == 3)
        #expect(position.text == "2 of 3")
        #expect(gallery.previous(of: middle) == first)
        #expect(gallery.next(of: middle) == last)

        #expect(gallery.position(of: first)?.text == "1 of 3")
        #expect(gallery.previous(of: first) == nil, "the first card has no previous")
        #expect(gallery.next(of: last) == nil, "the last card has no next")
        #expect(SpeciesGallery(Self.cards).position(of: middle)?.text == "4 of 6", "unfiltered, newest first")
    }

    @Test("a card the filter leaves out has no position")
    func positionOutsideFilter() {
        let gallery = SpeciesGallery(Self.cards, filter: .named(Self.sanDiego))
        let losAngelesCard = CardCollectionTests.uuid(1)

        #expect(gallery.position(of: losAngelesCard) == nil)
        #expect(gallery.previous(of: losAngelesCard) == nil)
        #expect(gallery.next(of: losAngelesCard) == nil)
    }
}
