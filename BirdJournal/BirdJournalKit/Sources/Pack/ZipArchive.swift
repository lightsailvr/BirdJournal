import Compression
import Foundation

/// Why a zip could not be unpacked.
public enum ZipError: Error, Equatable {
    case notAZipFile
    /// Zip64, encryption or a compression method other than stored and deflate.
    case unsupported(String)
    /// An entry name that would write outside the destination folder.
    case unsafePath(String)
    case corruptEntry(String)
}

/// The least of the zip format needed to unpack a species pack as `packbuilder` writes it (Python's `zipfile`,
/// deflated or stored entries, no zip64): the central directory is read from the end of the file, each entry is
/// read by its local header, inflated with Apple's Compression framework (raw deflate is `COMPRESSION_ZLIB` there)
/// and checked against its CRC-32. Entries are read one at a time, so a 165 MB pack never sits in memory whole.
enum ZipArchive {
    struct Entry {
        let name: String
        let method: UInt16
        let crc32: UInt32
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int

        var isDirectory: Bool { name.hasSuffix("/") }
    }

    /// Unpacks every entry of `zip` under `destination`, creating it. Refuses entry names that could escape it.
    static func extract(_ zip: URL, into destination: URL) throws {
        let file = try FileHandle(forReadingFrom: zip)
        defer { try? file.close() }
        let entries = try centralDirectory(of: file)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for entry in entries {
            guard isSafe(entry.name) else { throw ZipError.unsafePath(entry.name) }
            let target = destination.appending(path: entry.name)
            if entry.isDirectory {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try contents(of: entry, in: file)
            try data.write(to: target, options: .atomic)
        }
    }

    /// A relative path that stays inside its folder: no absolute path, drive, backslash or `..` component.
    static func isSafe(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":") else { return false }
        return !name.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." || $0 == "." }
    }

    // MARK: - Reading

    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50
    private static let centralFileHeaderSignature: UInt32 = 0x0201_4B50
    private static let localFileHeaderSignature: UInt32 = 0x0403_4B50
    private static let methodStored: UInt16 = 0
    private static let methodDeflate: UInt16 = 8

    private static func centralDirectory(of file: FileHandle) throws -> [Entry] {
        let length = try Int(file.seekToEnd())
        // The end record is 22 bytes plus a comment of at most 65,535 bytes; search the tail for its signature.
        let tailLength = min(length, 22 + 65_535)
        guard tailLength >= 22 else { throw ZipError.notAZipFile }
        try file.seek(toOffset: UInt64(length - tailLength))
        let tail = try read(file, count: tailLength)
        guard let endOffset = lastIndex(of: endOfCentralDirectorySignature, in: tail) else { throw ZipError.notAZipFile }
        let end = tail[endOffset...]
        let entryCount = Int(le16(end, 10)), directorySize = Int(le32(end, 12)), directoryOffset = Int(le32(end, 16))
        if entryCount == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            throw ZipError.unsupported("zip64")
        }
        guard directoryOffset + directorySize <= length else { throw ZipError.notAZipFile }
        try file.seek(toOffset: UInt64(directoryOffset))
        let directory = try read(file, count: directorySize)

        var entries: [Entry] = []
        var cursor = 0
        for _ in 0..<entryCount {
            guard cursor + 46 <= directory.count, le32(directory, cursor) == centralFileHeaderSignature else { throw ZipError.notAZipFile }
            let flags = le16(directory, cursor + 8)
            let method = le16(directory, cursor + 10)
            let nameLength = Int(le16(directory, cursor + 28)), extraLength = Int(le16(directory, cursor + 30)), commentLength = Int(le16(directory, cursor + 32))
            guard cursor + 46 + nameLength <= directory.count else { throw ZipError.notAZipFile }
            let name = String(decoding: directory[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)
            if flags & 0x1 != 0 { throw ZipError.unsupported("encrypted entry \(name)") }
            guard method == methodStored || method == methodDeflate else { throw ZipError.unsupported("compression method \(method) for \(name)") }
            entries.append(Entry(
                name: name, method: method, crc32: le32(directory, cursor + 16),
                compressedSize: Int(le32(directory, cursor + 20)), uncompressedSize: Int(le32(directory, cursor + 24)),
                localHeaderOffset: Int(le32(directory, cursor + 42))
            ))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    private static func contents(of entry: Entry, in file: FileHandle) throws -> Data {
        try file.seek(toOffset: UInt64(entry.localHeaderOffset))
        let header = try read(file, count: 30)
        guard le32(header, 0) == localFileHeaderSignature else { throw ZipError.corruptEntry(entry.name) }
        let nameLength = Int(le16(header, 26)), extraLength = Int(le16(header, 28))
        try file.seek(toOffset: UInt64(entry.localHeaderOffset + 30 + nameLength + extraLength))
        let compressed = try read(file, count: entry.compressedSize)
        let data: Data
        switch entry.method {
        case methodStored:
            data = compressed
        default:
            data = try inflate(compressed, expectedSize: entry.uncompressedSize, name: entry.name)
        }
        guard data.count == entry.uncompressedSize, crc32(data) == entry.crc32 else { throw ZipError.corruptEntry(entry.name) }
        return data
    }

    private static func inflate(_ compressed: Data, expectedSize: Int, name: String) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        var output = Data(count: expectedSize)
        let written = output.withUnsafeMutableBytes { destination in
            compressed.withUnsafeBytes { source in
                compression_decode_buffer(
                    destination.baseAddress!.assumingMemoryBound(to: UInt8.self), expectedSize,
                    source.baseAddress!.assumingMemoryBound(to: UInt8.self), compressed.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == expectedSize else { throw ZipError.corruptEntry(name) }
        return output
    }

    private static func read(_ file: FileHandle, count: Int) throws -> Data {
        let data = try file.read(upToCount: count) ?? Data()
        guard data.count == count else { throw ZipError.notAZipFile }
        return data
    }

    private static func lastIndex(of signature: UInt32, in data: Data) -> Int? {
        guard data.count >= 4 else { return nil }
        var index = data.count - 4
        while index >= 0 {
            if le32(data, index) == signature { return index }
            index -= 1
        }
        return nil
    }

    private static func le16(_ data: Data, _ offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        return UInt16(data[base]) | UInt16(data[base + 1]) << 8
    }

    private static func le32(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base]) | UInt32(data[base + 1]) << 8 | UInt32(data[base + 2]) << 16 | UInt32(data[base + 3]) << 24
    }

    // MARK: - CRC-32

    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    /// The zip CRC-32 (IEEE, reflected) of `data`.
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
