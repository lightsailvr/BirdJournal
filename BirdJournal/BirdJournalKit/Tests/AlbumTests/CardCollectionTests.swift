import Foundation
import Testing
@testable import Album

// Issue #51: every sighting is a card, and the birder's earliest surviving card of each species is Legendary. The
// collection is a pure reading of the sightings, so these tests build value snapshots and nothing is stored.
@Suite("Card collection")
struct CardCollectionTests {
    static let finch = "Haemorhous mexicanus_House Finch"
    static let phoebe = "Sayornis nigricans_Black Phoebe"
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    static func card(_ species: String, minutes: Double, id: Int) -> CardCollection.Entry {
        CardCollection.Entry(identifier: uuid(id), speciesID: species, confirmedAt: start.addingTimeInterval(minutes * 60))
    }

    /// A UUID whose string sorts by `n`, so tie-breaks read in the test.
    static func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }

    @Test("Legendary is the earliest surviving card of each species, whatever order the sightings arrive in")
    func earliestIsLegendary() {
        let cards = [
            Self.card(Self.finch, minutes: 30, id: 1),
            Self.card(Self.phoebe, minutes: 20, id: 2),
            Self.card(Self.finch, minutes: 10, id: 3),
            Self.card(Self.phoebe, minutes: 40, id: 4),
        ]

        let collection = CardCollection(cards.shuffled())

        #expect(collection.legendary == [Self.uuid(3), Self.uuid(2)])
        #expect(collection.isLegendary(Self.uuid(3)))
        #expect(!collection.isLegendary(Self.uuid(1)))
        #expect(collection.cards.map(\.identifier) == [Self.uuid(4), Self.uuid(1), Self.uuid(2), Self.uuid(3)], "newest first")
    }

    @Test("two cards of a species at the same moment: the lower identifier is Legendary")
    func tiesByIdentifier() {
        let collection = CardCollection([Self.card(Self.finch, minutes: 5, id: 9), Self.card(Self.finch, minutes: 5, id: 7)])
        #expect(collection.legendary == [Self.uuid(7)])
        #expect(collection.cards.map(\.identifier) == [Self.uuid(9), Self.uuid(7)], "the Legendary card sorts as the older")
    }

    @Test("deleting the Legendary card passes it to the next-earliest; deleting the last removes the species")
    func deletionPassesLegendaryOn() {
        let first = Self.card(Self.finch, minutes: 0, id: 1)
        let second = Self.card(Self.finch, minutes: 60, id: 2)
        let third = Self.card(Self.finch, minutes: 30, id: 3)
        let other = Self.card(Self.phoebe, minutes: 10, id: 4)

        #expect(CardCollection([first, second, third, other]).legendary == [Self.uuid(1), Self.uuid(4)])
        #expect(CardCollection([second, third, other]).legendary == [Self.uuid(3), Self.uuid(4)])
        #expect(CardCollection([second, other]).legendary == [Self.uuid(2), Self.uuid(4)])

        let withoutFinches = CardCollection([other])
        #expect(withoutFinches.speciesCount == 1)
        #expect(!withoutFinches.contains(speciesID: Self.finch))
        #expect(withoutFinches.legendary == [Self.uuid(4)])
    }

    @Test("two sightings of a species on the same day are two cards, one of them Legendary")
    func sameDayIsTwoCards() {
        let collection = CardCollection([Self.card(Self.finch, minutes: 0, id: 1), Self.card(Self.finch, minutes: 90, id: 2)])

        #expect(collection.cardCount == 2)
        #expect(collection.speciesCount == 1)
        #expect(collection.legendary.count == 1)
        #expect(collection.summary == "2 cards · 1 species")
        #expect(collection.cardsText == "2 cards")
        #expect(CardCollection([Self.card(Self.finch, minutes: 0, id: 1)]).summary == "1 card · 1 species")
    }

    @Test("an add makes a Legendary only when no other surviving card of its species exists")
    func addMakesLegendary() {
        let collection = CardCollection([Self.card(Self.finch, minutes: 0, id: 1)])
        #expect(!collection.addMakesLegendary(speciesID: Self.finch))
        #expect(collection.addMakesLegendary(speciesID: Self.phoebe))
        #expect(CardCollection([]).addMakesLegendary(speciesID: Self.finch))
    }

    @Test("the collection reads stored sightings")
    func fromSightings() {
        let sighting = Sighting(identifier: Self.uuid(5), speciesID: Self.finch, confirmedAt: Self.start, soundConfidence: 0.5, source: .phone)
        #expect(CardCollection.Entry(sighting) == Self.card(Self.finch, minutes: 0, id: 5))
    }

    @Test("the intro shows once, the first time the collection has a card")
    func introShowsOnce() throws {
        let suite = "collection-intro-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let intro = CollectionIntro(defaults: defaults)

        #expect(!intro.shouldShow(cardCount: 0), "nothing to show yet")
        #expect(intro.shouldShow(cardCount: 12))
        intro.markShown()
        #expect(!intro.shouldShow(cardCount: 12))
        #expect(!CollectionIntro(defaults: defaults).shouldShow(cardCount: 13), "remembered across launches")
    }
}
