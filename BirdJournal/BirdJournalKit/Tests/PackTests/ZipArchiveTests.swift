import Foundation
import Testing
@testable import Pack

/// The zip reader the phone unpacks downloaded packs with (issue #13): stored and deflated entries as Python's
/// `zipfile` writes them, nothing else.
@Suite("ZipArchive")
struct ZipArchiveTests {
    @Test("extracts every entry of a pack zip written by the builder, byte for byte")
    func extractsFixture() throws {
        let zip = try Fixtures.testPackZip()
        let out = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: out) }

        try ZipArchive.extract(zip, into: out)

        let names = try FileManager.default.subpathsOfDirectory(atPath: out.path(percentEncoded: false)).filter { !$0.hasSuffix(".DS_Store") }.sorted()
        #expect(names.contains("pack.sqlite"))
        #expect(names.contains("lens/1.jpg") && names.contains("phone/3.jpg") && names.contains("LICENSE"))
        let license = try String(contentsOf: out.appending(path: "LICENSE"), encoding: .utf8)
        #expect(license.contains("Sayornis nigricans"))
        let jpeg = try Data(contentsOf: out.appending(path: "lens/1.jpg"))
        #expect(jpeg.prefix(2) == Data([0xFF, 0xD8]), "a JPEG starts with FF D8")
        let pack = try SpeciesPack.open(directory: out)
        #expect(pack.species.map(\.commonName) == ["Black Phoebe", "Anna's Hummingbird"])
    }

    @Test("a stored entry is copied and directories are created; an entry that escapes the folder is refused")
    func storedAndTraversal() throws {
        let out = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: out) }
        let good = Fixtures.storedZip(entries: [("sub/", Data()), ("sub/hello.txt", Data("hello".utf8))])
        let goodURL = out.appending(path: "good.zip")
        try good.write(to: goodURL)
        try ZipArchive.extract(goodURL, into: out.appending(path: "good"))
        #expect(try String(contentsOf: out.appending(path: "good/sub/hello.txt"), encoding: .utf8) == "hello")

        let evilURL = out.appending(path: "evil.zip")
        try Fixtures.storedZip(entries: [("../escaped.txt", Data("no".utf8))]).write(to: evilURL)
        #expect(throws: ZipError.unsafePath("../escaped.txt")) {
            try ZipArchive.extract(evilURL, into: out.appending(path: "evil"))
        }
        #expect(!FileManager.default.fileExists(atPath: out.appending(path: "escaped.txt").path(percentEncoded: false)))
    }

    @Test("a file that is not a zip is reported")
    func notAZip() throws {
        let out = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: out) }
        let file = out.appending(path: "nope.zip")
        try Data(repeating: 0x41, count: 100).write(to: file)
        #expect(throws: ZipError.notAZipFile) {
            try ZipArchive.extract(file, into: out.appending(path: "nope"))
        }
    }
}

/// Test inputs: the builder's fixture pack zip, temp folders, and hand-built stored zips.
enum Fixtures {
    static func testPackZip() throws -> URL {
        try #require(Bundle.module.url(forResource: "test-pack", withExtension: "zip", subdirectory: "Fixtures"), "Fixtures/test-pack.zip is not in the test bundle")
    }

    static func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A zip of stored (uncompressed) entries: local headers, central directory, end record. Enough to exercise the
    /// reader's paths that the builder's deflated zip does not.
    static func storedZip(entries: [(name: String, data: Data)]) -> Data {
        var out = Data()
        var central = Data()
        for (name, data) in entries {
            let nameBytes = Data(name.utf8)
            let offset = UInt32(out.count)
            let crc = ZipArchive.crc32(data)
            out.append(le32(0x0403_4B50)); out.append(le16(20)); out.append(le16(0)); out.append(le16(0))
            out.append(le16(0)); out.append(le16(0)); out.append(le32(crc))
            out.append(le32(UInt32(data.count))); out.append(le32(UInt32(data.count)))
            out.append(le16(UInt16(nameBytes.count))); out.append(le16(0)); out.append(nameBytes); out.append(data)
            central.append(le32(0x0201_4B50)); central.append(le16(20)); central.append(le16(20)); central.append(le16(0)); central.append(le16(0))
            central.append(le16(0)); central.append(le16(0)); central.append(le32(crc))
            central.append(le32(UInt32(data.count))); central.append(le32(UInt32(data.count)))
            central.append(le16(UInt16(nameBytes.count))); central.append(le16(0)); central.append(le16(0))
            central.append(le16(0)); central.append(le16(0)); central.append(le32(0)); central.append(le32(offset)); central.append(nameBytes)
        }
        let centralOffset = UInt32(out.count)
        out.append(central)
        out.append(le32(0x0605_4B50)); out.append(le16(0)); out.append(le16(0))
        out.append(le16(UInt16(entries.count))); out.append(le16(UInt16(entries.count)))
        out.append(le32(UInt32(central.count))); out.append(le32(centralOffset)); out.append(le16(0))
        return out
    }

    private static func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private static func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
}
