import Foundation

/// Where sightings' camera frames live (spec "Album store": the most recent frame is written to disk and referenced
/// by path). Paths in `Sighting.frameImagePath` are relative to `directory`, so the album survives the app container
/// moving between installs and backups.
public struct FrameStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The app's frames folder under Application Support.
    public static func applicationSupport() throws -> FrameStore {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return FrameStore(directory: base.appending(path: "Frames", directoryHint: .isDirectory))
    }

    /// Writes one JPEG under a fresh name and returns the path to store on the sighting. The folder is created on
    /// first use.
    public func write(jpeg data: Data) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = "\(UUID().uuidString).jpg"
        try data.write(to: url(for: path), options: .atomic)
        return path
    }

    /// Where a sighting's frame is on disk.
    public func url(for frameImagePath: String) -> URL {
        directory.appending(path: frameImagePath)
    }
}
