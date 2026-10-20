import Foundation

/// One species' cards as a gallery (issue #53, collectible-cards style guide "Species gallery"): the header's counts
/// and first discovery, the place filter and the sort, the cards they show, and an opened card's position among them
/// ("3 of 15") with its previous and next. Pure over value snapshots of the species' sightings,
/// like `CardCollection`, so the gallery and an opened card compute the same order.
public struct SpeciesGallery: Sendable, Equatable {
    /// One card as the gallery reads it.
    public struct Card: Sendable, Hashable, Identifiable {
        public let identifier: UUID
        public let confirmedAt: Date
        /// The place's name as the phone shows it, nil when the sighting has no location ("Place not recorded").
        public let place: String?

        public var id: UUID { identifier }

        public init(identifier: UUID, confirmedAt: Date, place: String?) {
            self.identifier = identifier
            self.confirmedAt = confirmedAt
            self.place = place
        }
    }

    /// Which places the gallery shows.
    public enum PlaceFilter: Hashable, Sendable {
        case all
        /// The cards made at the place of that name.
        case named(String)
        /// The cards whose sighting has no location.
        case notRecorded

        /// "All places", the place's name, or "Place not recorded".
        public var title: String {
            switch self {
            case .all: "All places"
            case .named(let name): name
            case .notRecorded: "Place not recorded"
            }
        }
    }

    /// How the gallery orders its cards.
    public enum Sort: String, CaseIterable, Hashable, Sendable {
        case newest
        case oldest
        /// Alphabetically by place, newest first within a place, the cards with no place last.
        case place

        public var title: String {
            switch self {
            case .newest: "Newest first"
            case .oldest: "Oldest first"
            case .place: "By place"
            }
        }
    }

    /// One option of the place picker: a place the cards were made at, and how many.
    public struct Place: Hashable, Sendable, Identifiable {
        public let filter: PlaceFilter
        public let count: Int

        public var id: PlaceFilter { filter }
        public var title: String { filter.title }
    }

    /// A card's place in the shown order: `index` counts from 1.
    public struct Position: Hashable, Sendable {
        public let index: Int
        public let count: Int

        /// "3 of 15".
        public var text: String { "\(index) of \(count)" }
    }

    /// Every card of the species.
    public let cards: [Card]
    public let filter: PlaceFilter
    public let sort: Sort
    /// The cards the filter keeps, in the sort's order.
    public let shown: [Card]

    public init(_ cards: [Card], filter: PlaceFilter = .all, sort: Sort = .newest) {
        self.cards = cards
        self.filter = filter
        self.sort = sort
        shown = cards
            .filter { card in
                switch filter {
                case .all: true
                case .named(let name): card.place == name
                case .notRecorded: card.place == nil
                }
            }
            .sorted { lhs, rhs in
                switch sort {
                case .newest: Self.isNewer(lhs, rhs)
                case .oldest: Self.isNewer(rhs, lhs)
                case .place:
                    switch (lhs.place, rhs.place) {
                    case let (left?, right?) where left != right: left.localizedStandardCompare(right) == .orderedAscending
                    case (_?, nil): true
                    case (nil, _?): false
                    default: Self.isNewer(lhs, rhs)
                    }
                }
            }
    }

    /// Newest first, ties broken by identifier as the collection breaks them.
    private static func isNewer(_ lhs: Card, _ rhs: Card) -> Bool {
        if lhs.confirmedAt != rhs.confirmedAt { return lhs.confirmedAt > rhs.confirmedAt }
        return lhs.identifier.uuidString > rhs.identifier.uuidString
    }

    public var isFiltered: Bool { filter != .all }

    /// The place picker's options: each recorded place alphabetically with its count, then "Place not recorded" when
    /// any card has no location.
    public var places: [Place] {
        let counts = Dictionary(grouping: cards, by: \.place).mapValues(\.count)
        let named = counts
            .compactMap { name, count in name.map { Place(filter: .named($0), count: count) } }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let unplaced = counts[nil].map { [Place(filter: .notRecorded, count: $0)] } ?? []
        return named + unplaced
    }

    /// "15 cards", or "6 of 15 cards" under a filter.
    public var shownText: String {
        isFiltered ? "\(shown.count) of \(cardCount) cards" : "\(cardCount) \(cardCount == 1 ? "card" : "cards")"
    }

    public var cardCount: Int { cards.count }

    /// The distinct places the cards were made at; a card with no place counts for none.
    public var placeCount: Int { Set(cards.compactMap(\.place)).count }

    /// When the earliest card was made.
    public var firstDiscovery: Date? { cards.map(\.confirmedAt).min() }

    /// "House Finch · 15 cards · 2 places"; the places are left out when none was recorded.
    public func title(commonName: String) -> String {
        var parts = [commonName, "\(cardCount) \(cardCount == 1 ? "card" : "cards")"]
        if placeCount > 0 { parts.append("\(placeCount) \(placeCount == 1 ? "place" : "places")") }
        return parts.joined(separator: " · ")
    }

    /// Where `identifier` sits among the shown cards; nil when the filter leaves it out.
    public func position(of identifier: UUID) -> Position? {
        shown.firstIndex { $0.identifier == identifier }.map { Position(index: $0 + 1, count: shown.count) }
    }

    /// The shown card before `identifier`; nil at the first card or outside the filter.
    public func previous(of identifier: UUID) -> UUID? {
        neighbour(of: identifier, offset: -1)
    }

    /// The shown card after `identifier`; nil at the last card or outside the filter.
    public func next(of identifier: UUID) -> UUID? {
        neighbour(of: identifier, offset: 1)
    }

    private func neighbour(of identifier: UUID, offset: Int) -> UUID? {
        guard let index = shown.firstIndex(where: { $0.identifier == identifier }), shown.indices.contains(index + offset) else { return nil }
        return shown[index + offset].identifier
    }
}
