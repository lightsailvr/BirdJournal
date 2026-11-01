import Foundation

/// A set as the collection reads it (issue #54): the species of one pack's region in taxonomic order, which a birder
/// collects toward, with the region's boundary and the edition its cards carry. The app builds these from the set
/// definitions the packs and the pack index publish, so a set works before its pack is downloaded.
public struct CardSet: Sendable, Hashable, Identifiable {
    /// A point of a boundary, in degrees.
    public struct Point: Sendable, Hashable {
        public let longitude: Double
        public let latitude: Double

        public init(longitude: Double, latitude: Double) {
            self.longitude = longitude
            self.latitude = latitude
        }
    }

    /// One named part of the boundary (a county, a park, a hand-drawn region): polygons of an outer ring then holes.
    /// The parts stay apart because a sighting goes to the smallest part that contains it, so Anza-Borrego wins over
    /// San Diego County although the Deserts set as a whole is the larger.
    public struct Region: Sendable, Hashable {
        public let name: String
        /// Each polygon is its outer ring then its holes; each ring is closed (its first point repeated last).
        public let polygons: [[[Point]]]
        /// In square kilometres.
        public let area: Double
        private let bounds: (south: Double, west: Double, north: Double, east: Double)

        public init(name: String, polygons: [[[Point]]]) {
            self.name = name
            self.polygons = polygons
            area = polygons.reduce(0) { total, polygon in
                guard let outer = polygon.first else { return total }
                let latitude = Self.middleLatitude(outer)
                return total + Self.ringArea(outer, latitude: latitude) - polygon.dropFirst().reduce(0) { $0 + Self.ringArea($1, latitude: latitude) }
            }
            let points = polygons.flatMap { $0.first ?? [] }
            bounds = (
                points.map(\.latitude).min() ?? 0, points.map(\.longitude).min() ?? 0,
                points.map(\.latitude).max() ?? 0, points.map(\.longitude).max() ?? 0
            )
        }

        /// Whether the point is inside an outer ring and outside its holes (even-odd over the polygon's rings).
        public func contains(latitude: Double, longitude: Double) -> Bool {
            guard latitude >= bounds.south, latitude <= bounds.north, longitude >= bounds.west, longitude <= bounds.east else { return false }
            return polygons.contains { polygon in
                var inside = false
                for ring in polygon {
                    for (a, b) in zip(ring, ring.dropFirst()) where (a.latitude > latitude) != (b.latitude > latitude) {
                        let crossing = a.longitude + (latitude - a.latitude) * (b.longitude - a.longitude) / (b.latitude - a.latitude)
                        if longitude < crossing { inside.toggle() }
                    }
                }
                return inside
            }
        }

        public static func == (lhs: Region, rhs: Region) -> Bool {
            lhs.name == rhs.name && lhs.polygons == rhs.polygons
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(name)
            hasher.combine(polygons)
        }

        private static func middleLatitude(_ ring: [Point]) -> Double {
            let latitudes = ring.map(\.latitude)
            return ((latitudes.min() ?? 0) + (latitudes.max() ?? 0)) / 2
        }

        /// The shoelace area on a plane touching the earth at `latitude`, as the pack builder measures it.
        private static func ringArea(_ ring: [Point], latitude: Double) -> Double {
            let kmPerLongitude = 111.32 * cos(latitude * .pi / 180)
            let kmPerLatitude = 110.57
            let twice = zip(ring, ring.dropFirst()).reduce(0.0) { sum, pair in
                sum + pair.0.longitude * kmPerLongitude * pair.1.latitude * kmPerLatitude - pair.1.longitude * kmPerLongitude * pair.0.latitude * kmPerLatitude
            }
            return abs(twice) / 2
        }
    }

    /// The pack id, e.g. "us-ca-la".
    public let id: String
    /// "Los Angeles".
    public let name: String
    /// What cards of the set that are not Legendary show, e.g. "Citrus edition".
    public let edition: String
    /// Scientific names in taxonomic order; a species' collector number is its position from 1.
    public let species: [String]
    public let regions: [Region]
    private let positions: [String: Int]

    public init(id: String, name: String, edition: String, species: [String], regions: [Region]) {
        self.id = id
        self.name = name
        self.edition = edition
        self.species = species
        self.regions = regions
        positions = Dictionary(species.enumerated().map { ($1, $0 + 1) }, uniquingKeysWith: { first, _ in first })
    }

    public static func == (lhs: CardSet, rhs: CardSet) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.edition == rhs.edition && lhs.species == rhs.species && lhs.regions == rhs.regions
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(species)
    }

    /// The species' collector number in this set, from 1; nil when the set doesn't list it.
    public func number(of scientificName: String) -> Int? {
        positions[scientificName]
    }

    /// The area of the smallest part of the boundary that contains the point; nil when none does.
    func containingArea(latitude: Double, longitude: Double) -> Double? {
        regions.filter { $0.contains(latitude: latitude, longitude: longitude) }.map(\.area).min()
    }

    /// Where a card of `speciesID` (a BirdNET label) added at `location` belongs among `sets`: the set whose
    /// containing part is smallest among those listing the species, ties going to the lower id; else Uncharted, as for
    /// a sighting with no location.
    public static func placement(speciesID: String, at location: Coordinate?, in sets: [CardSet]) -> CardPlacement {
        guard let location else { return .uncharted }
        let scientificName = Sighting.scientificName(ofLabel: speciesID)
        let best = sets
            .compactMap { set -> (set: CardSet, number: Int, area: Double)? in
                guard let number = set.number(of: scientificName),
                      let area = set.containingArea(latitude: location.latitude, longitude: location.longitude)
                else { return nil }
                return (set, number, area)
            }
            .min { $0.area != $1.area ? $0.area < $1.area : $0.set.id < $1.set.id }
        guard let best else { return .uncharted }
        return .numbered(setID: best.set.id, setName: best.set.name, edition: best.set.edition, number: best.number, total: best.set.species.count)
    }
}

/// Which set a card belongs to and its collector number there, or Uncharted.
public enum CardPlacement: Sendable, Hashable {
    case numbered(setID: String, setName: String, edition: String, number: Int, total: Int)
    case uncharted

    /// What a card outside every set shows in place of a set's name, edition or number.
    public static let unchartedTitle = "Uncharted"

    /// "021/160", padded to three digits or to the set's size when it is larger; "Uncharted" outside every set.
    public var collectorNumber: String {
        switch self {
        case .numbered(_, _, _, let number, let total): "\(Self.paddedNumber(number, of: total))/\(Self.paddedNumber(total, of: total))"
        case .uncharted: Self.unchartedTitle
        }
    }

    /// `number` as a set of `total` species prints it: "021" of 160, "0021" of 1,200.
    public static func paddedNumber(_ number: Int, of total: Int) -> String {
        let digits = String(number)
        return String(repeating: "0", count: max(0, max(3, String(total).count) - digits.count)) + digits
    }

    public var setID: String? {
        if case .numbered(let setID, _, _, _, _) = self { return setID }
        return nil
    }

    /// "Los Angeles", or "Uncharted".
    public var setName: String {
        if case .numbered(_, let name, _, _, _) = self { return name }
        return Self.unchartedTitle
    }

    /// What a card that is not Legendary shows above its art: the set's edition, or "Uncharted".
    public var editionLabel: String {
        if case .numbered(_, _, let edition, _, _) = self { return edition }
        return Self.unchartedTitle
    }
}

/// How far a birder has collected one set: the distinct species of the set among the cards that belong to it.
public struct SetProgress: Sendable, Hashable, Identifiable {
    public let setID: String
    public let name: String
    public let collected: Int
    public let total: Int

    public var id: String { setID }

    public init(setID: String, name: String, collected: Int, total: Int) {
        self.setID = setID
        self.name = name
        self.collected = collected
        self.total = total
    }

    /// "Los Angeles · 87 of 160".
    public var text: String { "\(name) · \(collected) of \(total)" }
}
