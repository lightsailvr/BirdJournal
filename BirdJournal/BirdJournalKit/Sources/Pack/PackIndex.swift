import Foundation

/// One downloadable species pack as listed in the GitHub Releases JSON index.
public struct PackDescriptor: Codable, Sendable, Equatable, Identifiable {
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

/// The JSON index of packs available for download (DECISIONS.md, "Species pack").
public struct PackIndex: Codable, Sendable, Equatable {
    /// The pack compiled into the app binary so the first launch works offline.
    public static let bundledPackID = "us-ca-la"

    public let packs: [PackDescriptor]

    public init(packs: [PackDescriptor]) {
        self.packs = packs
    }

    public static func decode(from data: Data) throws -> PackIndex {
        try JSONDecoder().decode(PackIndex.self, from: data)
    }
}
