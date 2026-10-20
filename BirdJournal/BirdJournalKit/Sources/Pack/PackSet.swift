import Foundation

/// A pack's set definition (issue #54), as `packbuilder set` pins it in `set.json`: the region boundary in named parts,
/// the species in taxonomic order (a species' collector number is its position, from 1) and the edition. Schema-4 packs
/// carry it in their `set_definition` table and every pack index entry carries the same JSON, so the phone knows a set
/// before its pack is downloaded.
public struct PackSet: Codable, Sendable, Hashable, Identifiable {
    public struct Edition: Codable, Sendable, Hashable {
        /// On cards that are not Legendary, e.g. "Citrus edition".
        public let name: String
        /// What the set's pack art is painted with.
        public let theme: String
    }

    /// One part of the boundary: a county, a park or a hand-drawn region.
    public struct Region: Codable, Sendable, Hashable {
        public let name: String
        /// Where the boundary comes from, e.g. "US Census Bureau TIGER county 06037 (public domain)".
        public let source: String
        /// GeoJSON MultiPolygon coordinates: polygons of rings (the outer ring, then holes) of [longitude, latitude].
        public let polygons: [[[[Double]]]]
    }

    public struct Species: Codable, Sendable, Hashable {
        public let scientificName: String
        public let commonName: String
    }

    /// The pack id, e.g. "us-ca-la".
    public let id: String
    /// "Los Angeles".
    public let name: String
    public let edition: Edition
    /// The list the order follows, e.g. "IOC World Bird List 15.1".
    public let taxonomy: String
    public let regions: [Region]
    /// In taxonomic order.
    public let species: [Species]

    public static func decode(from data: Data) throws -> PackSet {
        try JSONDecoder().decode(PackSet.self, from: data)
    }
}
