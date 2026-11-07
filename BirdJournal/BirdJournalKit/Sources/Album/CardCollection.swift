import Foundation

/// The birder's collection of patches (issue #132, of #131; before it, cards with a Legendary, #51). A patch is one per
/// species per placement: the first sighting of a species in a set, or outside every set (Uncharted), sews its patch,
/// and every later sighting there adds to its count. A pure reading of value snapshots of the sightings, so it is
/// computed again whenever the album changes and nothing about a patch is stored: deleting a sighting lowers its
/// patch's count and moves its sewn date to the next-earliest, and deleting the last one unpicks the patch. Each
/// sighting belongs to a set of the ones the phone knows (`CardSet.placement`, #54), with its collector number and
/// edition, and each set has its progress, the patches sewn in it; a newly known set therefore pulls older sightings in.
public struct CardCollection: Sendable, Equatable {
    /// One sighting as the collection reads it.
    public struct Entry: Sendable, Hashable, Identifiable {
        public let identifier: UUID
        /// The BirdNET label.
        public let speciesID: String
        public let confirmedAt: Date
        /// Where the sighting was made, nil when no location was recorded (its patch is then Uncharted).
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

    /// One species' patch in one placement: its sightings there, newest first.
    public struct Patch: Sendable, Hashable, Identifiable {
        /// A patch is its species in its placement: the same patch whichever of its sightings survive.
        public struct Key: Sendable, Hashable {
            public let speciesID: String
            /// The set's id, nil for the Uncharted patch.
            public let setID: String?

            public init(speciesID: String, setID: String?) {
                self.speciesID = speciesID
                self.setID = setID
            }
        }

        public let speciesID: String
        public let placement: CardPlacement
        /// Never empty.
        public let sightings: [Entry]

        public var id: Key { Key(speciesID: speciesID, setID: placement.setID) }
        /// The scientific name half of the BirdNET label: the key the sets and the packs list.
        public var scientificName: String { Sighting.scientificName(ofLabel: speciesID) }
        public var count: Int { sightings.count }
        /// The earliest surviving sighting: the one that sewed the patch.
        public var sewn: Entry { sightings[sightings.count - 1] }
        public var latest: Entry { sightings[0] }

        /// "Seen once" or "Seen 8 times".
        public var countText: String { "Seen \(Self.times(count))" }

        /// "Seen 8 times in Los Angeles", or "Seen once, Uncharted" outside every set.
        public var seenAgainText: String {
            placement.setID == nil ? "\(countText), \(CardPlacement.unchartedTitle)" : "\(countText) in \(placement.setName)"
        }

        /// "once", "2 times", "8 times".
        public static func times(_ count: Int) -> String {
            count == 1 ? "once" : "\(count) times"
        }

        /// A species' patches in a line: "2 patches, seen 10 times".
        public static func speciesSummary(_ patches: [Patch]) -> String {
            "\(patches.count) \(patches.count == 1 ? "patch" : "patches"), seen \(times(patches.reduce(0) { $0 + $1.count }))"
        }
    }

    /// Every sighting, newest first.
    public let cards: [Entry]
    /// Every patch, the most recently sewn first.
    public let patches: [Patch]
    /// The sets the sightings were placed among.
    public let sets: [CardSet]
    /// Every set that has a patch, most collected first.
    public let progress: [SetProgress]
    /// Species with an Uncharted patch.
    public let unchartedSpeciesCount: Int
    private let species: Set<String>
    private let placements: [UUID: CardPlacement]
    private let patchByKey: [Patch.Key: Patch]
    /// The same patches by scientific name, in the `speciesID` of the key.
    private let patchByScientificName: [Patch.Key: Patch]
    private let keyBySighting: [UUID: Patch.Key]
    /// Scientific names collected per set id.
    private let collectedBySet: [String: Set<String>]

    public init(_ entries: [Entry], sets: [CardSet] = []) {
        cards = entries.sorted { Entry.isEarlier($1, $0) }
        species = Set(entries.map(\.speciesID))

        self.sets = sets
        var placements: [UUID: CardPlacement] = [:]
        var collected: [String: Set<String>] = [:]
        var uncharted = Set<String>()
        var grouped: [Patch.Key: (placement: CardPlacement, sightings: [Entry])] = [:]
        var keys: [UUID: Patch.Key] = [:]
        for entry in cards {
            let placement = CardSet.placement(speciesID: entry.speciesID, at: entry.location, in: sets)
            placements[entry.identifier] = placement
            let key = Patch.Key(speciesID: entry.speciesID, setID: placement.setID)
            keys[entry.identifier] = key
            if grouped[key] == nil {
                grouped[key] = (placement, [])
            }
            grouped[key]?.sightings.append(entry)
            if let setID = placement.setID {
                collected[setID, default: []].insert(entry.scientificName)
            } else {
                uncharted.insert(entry.scientificName)
            }
        }
        self.placements = placements
        keyBySighting = keys
        let byKey = grouped.mapValues { Patch(speciesID: $0.sightings[0].speciesID, placement: $0.placement, sightings: $0.sightings) }
        patchByKey = byKey
        patchByScientificName = Dictionary(byKey.values.map { (Patch.Key(speciesID: $0.scientificName, setID: $0.placement.setID), $0) }) { first, _ in first }
        patches = byKey.values.sorted { Entry.isEarlier($1.sewn, $0.sewn) }
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

    /// The sighting's set and collector number; nil for a sighting not in the collection.
    public func placement(of identifier: UUID) -> CardPlacement? {
        placements[identifier]
    }

    /// The patch the sighting belongs to; nil for a sighting not in the collection.
    public func patch(of identifier: UUID) -> Patch? {
        keyBySighting[identifier].flatMap { patchByKey[$0] }
    }

    /// The patch with this species and placement; nil when no sighting has sewn it.
    public func patch(key: Patch.Key) -> Patch? {
        patchByKey[key]
    }

    /// The species' patch in a set, nil for Uncharted, for whoever has only its scientific name: a pack's own label for a bird
    /// needn't be the BirdNET label its sightings carry.
    public func patch(scientificName: String, setID: String?) -> Patch? {
        patchByScientificName[Patch.Key(speciesID: scientificName, setID: setID)]
    }

    /// Whether the sighting is the one that sewed its patch: the patch's earliest surviving sighting.
    public func sewedItsPatch(_ identifier: UUID) -> Bool {
        patch(of: identifier)?.sewn.identifier == identifier
    }

    /// Whether deleting the sighting would unpick its patch: it is the patch's only sighting.
    public func isLastSighting(of identifier: UUID) -> Bool {
        patch(of: identifier)?.count == 1
    }

    /// What a patch shows as its edition: its set's edition, or "Uncharted". Nil for a sighting not in the collection.
    public func editionLabel(of identifier: UUID) -> String? {
        placement(of: identifier)?.editionLabel
    }

    /// The set's patches in collector-number order.
    public func patches(in setID: String) -> [Patch] {
        patches
            .filter { $0.placement.setID == setID }
            .sorted { lhs, rhs in
                guard case .numbered(_, _, _, let left, _) = lhs.placement, case .numbered(_, _, _, let right, _) = rhs.placement else { return false }
                return left < right
            }
    }

    /// The patches outside every set, the most recently sewn first.
    public var unchartedPatches: [Patch] {
        patches.filter { $0.placement.setID == nil }
    }

    /// Every patch in the order a page swipes through them: each set as the phone knows them, in collector-number order,
    /// then the patches outside every set.
    public var browsingOrder: [Patch] {
        sets.flatMap { patches(in: $0.id) } + unchartedPatches
    }

    /// One species' patches across its placements, the earliest sewn first.
    public func patches(of speciesID: String) -> [Patch] {
        patches.filter { $0.speciesID == speciesID }.sorted { Entry.isEarlier($0.sewn, $1.sewn) }
    }

    /// The progress of one set, zero when no patch belongs to it yet; zero of zero for a set the collection doesn't know.
    public func progress(of setID: String) -> SetProgress {
        guard let set = sets.first(where: { $0.id == setID }) else { return SetProgress(setID: setID, name: setID, collected: 0, total: 0) }
        return SetProgress(setID: set.id, name: set.name, collected: collectedBySet[setID]?.count ?? 0, total: set.species.count)
    }

    /// The scientific names of the set's species that have a patch in it.
    public func collected(in setID: String) -> Set<String> {
        collectedBySet[setID] ?? []
    }

    public func contains(speciesID: String) -> Bool {
        species.contains(speciesID)
    }

    /// The patch an add of `speciesID` at `location` would join, nil when the add would sew a new one.
    public func patch(forSpeciesID speciesID: String, at location: Coordinate?) -> Patch? {
        let placement = CardSet.placement(speciesID: speciesID, at: location, in: sets)
        return patchByKey[Patch.Key(speciesID: speciesID, setID: placement.setID)]
    }

    /// Whether an add of `speciesID` at `location` sews a patch: no surviving sighting of the species is in the
    /// placement the add will have. The sewing belongs to the add, so reopening a patch never shows it again.
    public func addSewsPatch(speciesID: String, at location: Coordinate?) -> Bool {
        patch(forSpeciesID: speciesID, at: location) == nil
    }

    /// How many sightings of `speciesID` are in the placement an add at `location` would have.
    public func count(ofSpeciesID speciesID: String, at location: Coordinate?) -> Int {
        patch(forSpeciesID: speciesID, at: location)?.count ?? 0
    }

    public var sightingCount: Int { cards.count }
    public var patchCount: Int { patches.count }
    public var speciesCount: Int { species.count }

    /// "7 patches" or "1 patch".
    public var patchesText: String {
        "\(patchCount) \(patchCount == 1 ? "patch" : "patches")"
    }

    /// The Collection's line under its title, e.g. "7 patches, 21 sightings".
    public var summary: String {
        "\(patchesText), \(sightingCount) \(sightingCount == 1 ? "sighting" : "sightings")"
    }
}

/// The one-time "your collection so far" moment (issue #51): the sightings a birder had before the collection existed
/// become their starting patches in one moment rather than a sewing per species. It shows the first time the
/// collection has a patch and is remembered from then on.
public struct CollectionIntro {
    public static let defaultsKey = "collectionIntroShown"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func shouldShow(patchCount: Int) -> Bool {
        patchCount > 0 && !defaults.bool(forKey: Self.defaultsKey)
    }

    public func markShown() {
        defaults.set(true, forKey: Self.defaultsKey)
    }
}

/// One collection kept between readings (issue #150): building it places every sighting in its set's polygons, so the app
/// builds it when the sightings or the sets change, not whenever a screen draws. `update` compares what it's given with what
/// the collection was built from, so whoever feeds it can do so on any save.
public struct CardCollectionCache: Sendable {
    public private(set) var collection: CardCollection
    private var entries: [CardCollection.Entry]
    private var sets: [CardSet]

    public init(_ entries: [CardCollection.Entry], sets: [CardSet]) {
        self.entries = entries
        self.sets = sets
        collection = CardCollection(entries, sets: sets)
    }

    /// Builds again if the sightings or the sets differ from the last time, and says whether it did.
    @discardableResult
    public mutating func update(_ entries: [CardCollection.Entry], sets: [CardSet]) -> Bool {
        guard entries != self.entries || sets != self.sets else { return false }
        self.entries = entries
        self.sets = sets
        collection = CardCollection(entries, sets: sets)
        return true
    }
}
