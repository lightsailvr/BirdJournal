import Foundation

/// One downloadable species pack as listed in the GitHub Releases JSON index. The counts and the region are what the
/// packs screen shows before a pack is on the phone (issue #28); an index written before they existed leaves them
/// nil and the screen shows what it has.
public struct PackDescriptor: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let version: Int
    public let url: URL
    public let sha256: String
    public let byteCount: Int
    /// Species in the pack, from its database at pin time.
    public let speciesCount: Int?
    /// Photos in the pack, from its database at pin time.
    public let photoCount: Int?
    /// The region the pack covers, e.g. "Los Angeles County, California, US".
    public let region: String?
    /// Reference sounds in the pack (issue #41).
    public let soundCount: Int?
    /// The pack database's schema (issue #41); nil in an index written before it was listed, which means schema 2.
    public let schemaVersion: Int?

    /// Whether this build can open the pack. A pack of a newer schema is listed but not offered for download.
    public var isSupported: Bool {
        SpeciesPack.supportedSchemaVersions.contains(schemaVersion ?? 2)
    }

    public init(
        id: String, name: String, version: Int, url: URL, sha256: String, byteCount: Int, speciesCount: Int? = nil, photoCount: Int? = nil,
        region: String? = nil, soundCount: Int? = nil, schemaVersion: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.url = url
        self.sha256 = sha256
        self.byteCount = byteCount
        self.speciesCount = speciesCount
        self.photoCount = photoCount
        self.region = region
        self.soundCount = soundCount
        self.schemaVersion = schemaVersion
    }
}

/// The JSON index of packs available for download (DECISIONS.md, "Species pack"): `index.json` on the `packs` release
/// of this repository, written by `scripts/publish-pack-index.sh` from `packs/manifest.json`. It lists the bundled
/// pack too, so one file describes every pack there is.
public struct PackIndex: Codable, Sendable, Equatable {
    /// The pack compiled into the app binary so the first launch works offline.
    public static let bundledPackID = "us-ca-la"
    /// Where the app fetches the index.
    public static let defaultURL = URL(string: "https://github.com/lightsailvr/BirdJournal/releases/download/packs/index.json")!

    public let packs: [PackDescriptor]

    public init(packs: [PackDescriptor]) {
        self.packs = packs
    }

    /// The index's entry for a pack id, if it lists one.
    public func descriptor(id: String) -> PackDescriptor? {
        packs.first { $0.id == id }
    }

    public static func decode(from data: Data) throws -> PackIndex {
        try JSONDecoder().decode(PackIndex.self, from: data)
    }

    /// Fetches and decodes the index at `url`, bypassing caches so a republished index is seen at once.
    public static func fetch(from url: URL, session: URLSession = .shared) async throws -> PackIndex {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PackDownloadError.httpStatus(http.statusCode)
        }
        return try decode(from: data)
    }
}
