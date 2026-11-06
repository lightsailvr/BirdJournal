import Foundation
import OSLog

/// What `CircleStore` keeps on disk between launches (issue #150), so a Guild's screens draw at once and refresh in place: the
/// list, each Guild's detail and goals, and the first page of its feed. The same JSON the server sends, read by the same
/// decoders.
struct CircleSnapshot: Codable, Equatable, Sendable {
    /// Bumped when the shape changes; a snapshot of another version is thrown away, as any cache can be.
    static let currentVersion = 1

    var version = Self.currentVersion
    var circles: [CircleSummary] = []
    /// By circle id.
    var details: [String: CircleDetail] = [:]
    /// Each circle's first page, by circle id.
    var feeds: [String: FeedPage] = [:]
    /// By circle id.
    var goals: [String: [CircleGoal]] = [:]
}

/// The snapshot's file. It holds friends' names and finds, so it stays out of backups, in Caches, and goes at sign-out and
/// account deletion. A snapshot is small enough to encode on the main actor; the writes happen in turn off it, and `remove`
/// waits for them, so nothing is on disk once it returns.
final class CircleCache {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.matthewcelia.mybirdjournal.circle-cache", qos: .utility)
    private nonisolated static let log = Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "circles")

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// The app's cache, in Caches.
    static func forApp() -> CircleCache {
        CircleCache(fileURL: URL.cachesDirectory.appending(path: "Guilds/last-known.json"))
    }

    /// The last snapshot; nil when there is none, or it can't be read, which also removes it.
    func load() -> CircleSnapshot? {
        finishWrites()
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(CircleSnapshot.self, from: data), snapshot.version == CircleSnapshot.currentVersion else {
            Self.log.error("the Guild cache couldn't be read, so it goes")
            remove()
            return nil
        }
        return snapshot
    }

    func save(_ snapshot: CircleSnapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else {
            Self.log.error("couldn't encode the Guild cache")
            return
        }
        queue.async { [fileURL] in
            do {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch {
                Self.log.error("couldn't write the Guild cache: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func remove() {
        queue.sync { [fileURL] in
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    /// Waits for the writes already asked for.
    func finishWrites() {
        queue.sync {}
    }
}
