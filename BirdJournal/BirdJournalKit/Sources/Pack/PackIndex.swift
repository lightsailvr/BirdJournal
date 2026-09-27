import Foundation

/// One downloadable species pack as listed in the GitHub Releases JSON index.
public struct PackDescriptor: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let version: Int
    public let url: URL
    public let sha256: String
    public let byteCount: Int

    public init(id: String, name: String, version: Int, url: URL, sha256: String, byteCount: Int) {
        self.id = id
        self.name = name
        self.version = version
        self.url = url
        self.sha256 = sha256
        self.byteCount = byteCount
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
