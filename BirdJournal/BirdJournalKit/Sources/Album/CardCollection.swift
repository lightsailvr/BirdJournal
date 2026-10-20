import Foundation

/// The birder's collection (issue #51): every sighting is one card, and the earliest surviving card of each species
/// is Legendary. A pure reading of value snapshots of the sightings, so it is computed again whenever the album
/// changes and nothing about a card is stored: deleting a Legendary card passes the status to the next-earliest, and
/// deleting the last card of a species takes the species out of the collection. Since issue #54 each card also belongs
/// to a set of the ones the phone knows (`CardSet.placement`), with its collector number and edition, and each set has
/// its progress; a newly known set therefore pulls older sightings in.
public struct CardCollection: Sendable, Equatable {
    /// One sighting as the collection reads it.
    public struct Entry: Sendable, Hashable, Identifiable {
        public let identifier: UUID
        /// The BirdNET label.
        public let speciesID: String
        public let confirmedAt: Date
        /// Where the sighting was made, nil when no location was recorded (the card is then Uncharted).
        public let location: Coordinate?

        public var id: UUID { identifier }

        /// The scientific name half of the BirdNET label: the key the sets list.
        public var scientificName: String { Sighting.scientificName(ofLabel: speciesID) }

        public init(identifier: UUID, speciesID: String, confirmedAt: Date, location: Coordinate? = nil) {
            self.identifier = identifier
            self.speciesID = speciesID
            self.confirmedAt = confirmedAt
            self.location = location
        }

        public init(_ sighting: Sighting) {
            self.init(identifier: sighting.identifier, speciesID: sighting.speciesID, confirmedAt: sighting.confirmedAt, location: sighting.location)
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
    /// The sets the cards were placed among.
    public let sets: [CardSet]
    /// Every set that has a card, most collected first.
    public let progress: [SetProgress]
    /// Species with an Uncharted card.
    public let unchartedSpeciesCount: Int
    private let species: Set<String>
    private let placements: [UUID: CardPlacement]
    /// Scientific names collected per set id.
    private let collectedBySet: [String: Set<String>]

    public init(_ entries: [Entry], sets: [CardSet] = []) {
        cards = entries.sorted { Entry.isEarlier($1, $0) }
        var earliest: [String: Entry] = [:]
        for entry in entries where earliest[entry.speciesID].map({ Entry.isEarlier(entry, $0) }) ?? true {
            earliest[entry.speciesID] = entry
        }
        legendary = Set(earliest.values.map(\.identifier))
        species = Set(earliest.keys)

        self.sets = sets
        var placements: [UUID: CardPlacement] = [:]
        var collected: [String: Set<String>] = [:]
        var uncharted = Set<String>()
        for entry in entries {
            let placement = CardSet.placement(speciesID: entry.speciesID, at: entry.location, in: sets)
            placements[entry.identifier] = placement
            if let setID = placement.setID {
                collected[setID, default: []].insert(entry.scientificName)
            } else {
                uncharted.insert(entry.scientificName)
            }
        }
        self.placements = placements
        collectedBySet = collected
        unchartedSpeciesCount = uncharted.count
        progress = sets
            .filter { collected[$0.id] != nil }
            .map { SetProgress(setID: $0.id, name: $0.name, collected: collected[$0.id]?.count ?? 0, total: $0.species.count) }
            .sorted { $0.collected != $1.collected ? $0.collected > $1.collected : $0.name < $1.name }
    }

    public init(sightings: [Sighting], sets: [CardSet] = []) {
        self.init(sightings.map(Entry.init), sets: sets)
    }

    public func isLegendary(_ identifier: UUID) -> Bool {
        legendary.contains(identifier)
    }

    /// The card's set and collector number; nil for a card not in the collection.
    public func placement(of identifier: UUID) -> CardPlacement? {
        placements[identifier]
    }

    /// What the card shows above its art when it is not Legendary: its set's edition, or "Uncharted". Nil for a
    /// Legendary card, which shows "Legendary · Your first" instead, and for a card not in the collection.
    public func editionLabel(of identifier: UUID) -> String? {
        guard !isLegendary(identifier) else { return nil }
        return placement(of: identifier)?.editionLabel
    }

    /// The progress of one set, zero when no card belongs to it yet; zero of zero for a set the collection doesn't know.
    public func progress(of setID: String) -> SetProgress {
        guard let set = sets.first(where: { $0.id == setID }) else { return SetProgress(setID: setID, name: setID, collected: 0, total: 0) }
        return SetProgress(setID: set.id, name: set.name, collected: collectedBySet[setID]?.count ?? 0, total: set.species.count)
    }

    /// The scientific names of the set's species that have a card in it: the rest show as silhouettes.
    public func collected(in setID: String) -> Set<String> {
        collectedBySet[setID] ?? []
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
