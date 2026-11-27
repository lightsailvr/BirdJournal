import Foundation
import Testing
import PackFixture
@testable import Album

// Issue #210: the North America set is bounded by two countries, the United States (the 50 states and DC) and Canada,
// pushed a little offshore. These tests place sightings against the boundary the pack builder drew: the set definition
// in Fixtures/united-states-and-canada, which `packbuilder set` writes from the pack.json beside it (five birds, no
// pack). The same file is what the builder's own tests check.
@Suite("Placement in a set bounded by countries")
struct CountryBoundaryPlacementTests {
    static let robin = "Turdus migratorius_American Robin"

    /// The fixture's set as the app would hand it to placement.
    static let continental: CardSet = {
        struct Definition: Decodable {
            struct Edition: Decodable { let name: String }
            struct Region: Decodable {
                let name: String
                let polygons: [[[[Double]]]]
            }
            struct Species: Decodable { let scientificName: String }
            let id: String
            let name: String
            let edition: Edition
            let regions: [Region]
            let species: [Species]
        }
        let url = Bundle.module.url(forResource: "set", withExtension: "json", subdirectory: "Fixtures/united-states-and-canada")!
        let definition = try! JSONDecoder().decode(Definition.self, from: Data(contentsOf: url))
        return CardSet(
            id: definition.id, name: definition.name, edition: definition.edition.name,
            species: definition.species.map(\.scientificName),
            regions: definition.regions.map { region in
                CardSet.Region(name: region.name, polygons: region.polygons.map { $0.map { $0.map { CardSet.Point(longitude: $0[0], latitude: $0[1]) } } })
            }
        )
    }()

    static func place(_ latitude: Double, _ longitude: Double) -> Coordinate {
        Coordinate(latitude: latitude, longitude: longitude, accuracy: 10)
    }

    static let inside: [(String, Coordinate)] = [
        ("Chicago", place(41.88, -87.63)), ("Denver", place(39.74, -104.99)), ("Winnipeg", place(49.90, -97.14)),
        ("Anchorage", place(61.22, -149.90)), ("Honolulu", place(21.31, -157.86)), ("Halifax", place(44.65, -63.58)),
        ("Attu, east of 180°", place(52.9, 173.2)), ("Fort Jefferson, Dry Tortugas", place(24.628, -82.873)),
        ("Santa Ana NWR, on the Rio Grande", place(26.08, -98.135)),
        ("the end of Santa Monica Pier", place(34.0083, -118.4987)), ("a boat 4 km off Santa Monica", place(33.98, -118.53)),
        ("a boat off Tofino", place(49.11, -125.97)), ("the middle of Lake Michigan", place(43.4, -87.0)),
    ]

    static let outside: [(String, Coordinate)] = [
        ("Mexico City", place(19.43, -99.13)), ("Ensenada", place(31.87, -116.60)), ("Havana", place(23.11, -82.37)),
        ("Nuuk", place(64.18, -51.72)), ("San Juan, Puerto Rico", place(18.47, -66.11)), ("Guam", place(13.44, 144.79)),
        ("the mid-Atlantic", place(40.0, -40.0)), ("between California and Hawaii", place(30.0, -140.0)),
        ("London", place(51.51, -0.13)),
    ]

    @Test("the builder's boundary is one part of a few dozen coarse polygons")
    func theFixtureIsTheBuildersBoundary() throws {
        let region = try #require(Self.continental.regions.first)
        #expect(Self.continental.regions.count == 1)
        #expect(region.name == "United States and Canada")
        #expect(Self.continental.species.count == 5)
        #expect(region.polygons.count > 10, "the mainland, Hawaii, the Aleutians either side of 180° and the far islands")
        #expect(region.polygons.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } } < 2_000, "every placement walks these points")
    }

    @Test("a robin in the United States or Canada, or just off their coasts, is a patch of the set", arguments: inside)
    func placedInside(name: String, location: Coordinate) {
        let placement = CardSet.placement(speciesID: Self.robin, at: location, in: [Self.continental])
        #expect(
            placement == .numbered(setID: "fixture-united-states-and-canada", setName: "United States and Canada", edition: "Continental edition", number: 3, total: 5),
            "\(name)"
        )
        #expect(CardSet.containing(location, in: [Self.continental])?.id == Self.continental.id, "\(name)")
    }

    @Test("a robin abroad, in a territory or in mid-ocean is Uncharted", arguments: outside)
    func leftOutside(name: String, location: Coordinate) {
        #expect(CardSet.placement(speciesID: Self.robin, at: location, in: [Self.continental]) == .uncharted, "\(name)")
        #expect(CardSet.containing(location, in: [Self.continental]) == nil, "\(name)")
    }

    @Test("a county inside the two countries is the smaller part, so its set takes a bird both list")
    func aCountyInsideIsSmaller() {
        // A box close to Los Angeles County.
        let corners = [(-118.95, 33.70), (-117.65, 33.70), (-117.65, 34.82), (-118.95, 34.82), (-118.95, 33.70)]
        let county = CardSet(
            id: LosAngelesSet.id, name: "Los Angeles", edition: "Citrus edition", species: ["Turdus migratorius"],
            regions: [CardSet.Region(name: "Los Angeles County", polygons: [[corners.map { CardSet.Point(longitude: $0.0, latitude: $0.1) }]])]
        )
        let griffithPark = Self.place(34.13, -118.29)
        #expect(CardSet.placement(speciesID: Self.robin, at: griffithPark, in: [Self.continental, county]).setID == LosAngelesSet.id)
        #expect(CardSet.placement(speciesID: Self.robin, at: griffithPark, in: [Self.continental]).setID == Self.continental.id)
        #expect(CardSet.placement(speciesID: Self.robin, at: Self.place(41.88, -87.63), in: [Self.continental, county]).setID == Self.continental.id)
    }
}
