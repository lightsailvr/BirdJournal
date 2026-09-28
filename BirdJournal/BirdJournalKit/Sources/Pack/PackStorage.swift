import CryptoKit
import Foundation
import OSLog

/// A downloaded pack on disk: what the index said it was, and its contents.
public struct InstalledPack: Sendable, Hashable, Identifiable {
    public let descriptor: PackDescriptor
    public let pack: SpeciesPack

    public var id: String { descriptor.id }
}

/// Why a downloaded zip was not installed.
public enum PackInstallError: Error, Equatable {
    case checksumMismatch(expected: String, actual: String)
    /// The zip holds a pack with another id than the index entry it was downloaded for.
    case wrongPack(expected: String, actual: String)
}

/// Downloaded packs on disk (issue #13): one folder per pack under `directory` (Application Support/Packs in the
/// app), holding the unpacked zip and `installed.json`, the descriptor it was installed from. The folder is not
/// backed up: a pack is re-downloadable. Installing goes through `<id>.unpacking`, so a pack folder either holds a
/// whole verified pack or does not exist.
public struct PackStorage: Sendable {
    static let recordFile = "installed.json"
    static let stagingSuffix = ".unpacking"
    static let replacedSuffix = ".replaced"
    private static let log = Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "packs")

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The app's packs folder under Application Support.
    public static func applicationSupport() throws -> PackStorage {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return PackStorage(directory: base.appending(path: "Packs", directoryHint: .isDirectory))
    }

    /// Where a pack with this id lives, installed or not.
    public func url(for id: String) -> URL {
        directory.appending(path: id, directoryHint: .isDirectory)
    }

    /// Every pack installed here, in name order. A folder that no longer opens (a schema this build does not read,
    /// a half-deleted pack) is logged and skipped, never fatal; a staging folder a crash left behind is deleted.
    public func installed() -> [InstalledPack] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) else { return [] }
        var packs: [InstalledPack] = []
        for name in names.sorted() {
            let folder = url(for: name)
            if name.hasSuffix(Self.stagingSuffix) || name.hasSuffix(Self.replacedSuffix) {
                // A staging folder a crash left behind, or a previous version set aside during an update that did
                // not finish: the final folder is whole either way.
                try? FileManager.default.removeItem(at: folder)
                continue
            }
            let record = folder.appending(path: Self.recordFile)
            guard FileManager.default.fileExists(atPath: record.path(percentEncoded: false)) else { continue }
            do {
                let descriptor = try JSONDecoder().decode(PackDescriptor.self, from: Data(contentsOf: record))
                packs.append(InstalledPack(descriptor: descriptor, pack: try SpeciesPack.open(directory: folder)))
            } catch {
                Self.log.error("installed pack \(name) does not open: \(String(describing: error))")
            }
        }
        return packs
    }

    /// Checks `zip` against `descriptor.sha256`, unpacks it and records the descriptor beside it, replacing any
    /// earlier install of the same pack. The record is written last, after the move, so a folder holding one is a
    /// whole pack under its final name. The zip is left where it was.
    public func install(zip: URL, as descriptor: PackDescriptor) throws -> InstalledPack {
        let actual = try Self.sha256(of: zip)
        guard actual == descriptor.sha256.lowercased() else {
            throw PackInstallError.checksumMismatch(expected: descriptor.sha256, actual: actual)
        }
        let staging = directory.appending(path: descriptor.id + Self.stagingSuffix, directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: staging)
        do {
            try createDirectoryExcludedFromBackup()
            try ZipArchive.extract(zip, into: staging)
            let unpacked = try SpeciesPack.open(directory: staging)  // a zip that is not a readable pack never lands
            guard unpacked.info.id == descriptor.id else { throw PackInstallError.wrongPack(expected: descriptor.id, actual: unpacked.info.id) }
            let final = url(for: descriptor.id)
            try replace(final, with: staging)
            try JSONEncoder().encode(descriptor).write(to: final.appending(path: Self.recordFile), options: .atomic)
            return InstalledPack(descriptor: descriptor, pack: try SpeciesPack.open(directory: final))
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// Puts the unpacked `staging` folder at `final`. An earlier install there is set aside, not deleted, until the
    /// new one is in place, and put back if the move fails, so a failed update never loses a working pack.
    private func replace(_ final: URL, with staging: URL) throws {
        let previous = directory.appending(path: final.lastPathComponent + Self.replacedSuffix, directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: previous)
        let hadPrevious = FileManager.default.fileExists(atPath: final.path(percentEncoded: false))
        if hadPrevious { try FileManager.default.moveItem(at: final, to: previous) }
        do {
            try FileManager.default.moveItem(at: staging, to: final)
        } catch {
            if hadPrevious { try? FileManager.default.moveItem(at: previous, to: final) }
            throw error
        }
        try? FileManager.default.removeItem(at: previous)
    }

    /// The bytes a pack's folder takes on disk, installed or bundled: what removing it frees.
    public static func diskUsage(of directory: URL) -> Int64 {
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    /// Free space on the volume the packs go to, for the check before a download; nil when it cannot be read.
    public func availableCapacity() -> Int64? {
        let probe = FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) ? directory : directory.deletingLastPathComponent()
        return try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
    }

    /// Deletes the pack's folder; nothing to delete is fine.
    public func remove(id: String) throws {
        let folder = url(for: id)
        guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else { return }
        try FileManager.default.removeItem(at: folder)
    }

    /// The hex SHA-256 of a file, read in 1 MB pieces.
    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let piece = try handle.read(upToCount: 1 << 20), !piece.isEmpty {
            hasher.update(data: piece)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func createDirectoryExcludedFromBackup() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var folder = directory
        try folder.setResourceValues(values)
    }
}
