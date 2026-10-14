import Foundation

/// The birder's collection (issue #51): every sighting is one card, and the earliest surviving card of each species
/// is Legendary. A pure reading of value snapshots of the sightings, so it is computed again whenever the album
/// changes and nothing about a card is stored: deleting a Legendary card passes the status to the next-earliest, and
/// deleting the last card of a species takes the species out of the collection.
public struct CardCollection: Sendable, Equatable {
    /// One sighting as the collection reads it.
    public struct Entry: Sendable, Hashable, Identifiable {
        public let identifier: UUID
        /// The BirdNET label.
        public let speciesID: String
        public let confirmedAt: Date

        public var id: UUID { identifier }

        public init(identifier: UUID, speciesID: String, confirmedAt: Date) {
            self.identifier = identifier
            self.speciesID = speciesID
            self.confirmedAt = confirmedAt
        }

        public init(_ sighting: Sighting) {
            self.init(identifier: sighting.identifier, speciesID: sighting.speciesID, confirmedAt: sighting.confirmedAt)
        }

        /// Collection order: by confirmation time, ties broken by identifier.
        static func isEarlier(_ lhs: Entry, _ rhs: Entry) -> Bool {
            if lhs.confirmedAt != rhs.confirmedAt { return lhs.confirmedAt < rhs.confirmedAt }
            return lhs.identifier.uuidString < rhs.identifier.uuidString
        }
    }

    /// Every card, newest first.
    public let cards: [Entry]
    /// The Legendary card of each species in the collection.
    public let legendary: Set<UUID>
    private let species: Set<String>

    public init(_ entries: [Entry]) {
        cards = entries.sorted { Entry.isEarlier($1, $0) }
        var earliest: [String: Entry] = [:]
        for entry in entries where earliest[entry.speciesID].map({ Entry.isEarlier(entry, $0) }) ?? true {
            earliest[entry.speciesID] = entry
        }
        legendary = Set(earliest.values.map(\.identifier))
        species = Set(earliest.keys)
    }

    public init(sightings: [Sighting]) {
        self.init(sightings.map(Entry.init))
    }

    public func isLegendary(_ identifier: UUID) -> Bool {
        legendary.contains(identifier)
    }

    public func contains(speciesID: String) -> Bool {
        species.contains(speciesID)
    }

    /// Whether an add of `speciesID` now earns the Legendary reveal: no other surviving card of the species exists.
    /// The reveal belongs to the add, so reopening a card never shows it again.
    public func addMakesLegendary(speciesID: String) -> Bool {
        !contains(speciesID: speciesID)
    }

    public var cardCount: Int { cards.count }
    public var speciesCount: Int { species.count }

    /// "28 cards" or "1 card".
    public var cardsText: String {
        "\(cardCount) \(cardCount == 1 ? "card" : "cards")"
    }

    /// The Cards view's line under the title, e.g. "28 cards · 12 species".
    public var summary: String {
        "\(cardsText) · \(speciesCount) species"
    }
}

/// The one-time "your collection so far" moment (issue #51): the sightings a birder had before cards existed become
/// their starting collection in one moment rather than a reveal per species. It shows the first time the collection
/// has a card and is remembered from then on.
public struct CollectionIntro {
    public static let defaultsKey = "collectionIntroShown"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func shouldShow(cardCount: Int) -> Bool {
        cardCount > 0 && !defaults.bool(forKey: Self.defaultsKey)
    }

    public func markShown() {
        defaults.set(true, forKey: Self.defaultsKey)
    }
}
