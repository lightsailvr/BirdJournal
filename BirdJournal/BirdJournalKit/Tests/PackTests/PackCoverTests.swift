import Foundation
import ImageIO
import SQLite3
import Testing
@testable import Pack

/// Set covers (issue #114): a pack carries its set's approved cover (16:9 AVIF) with its credit, the pack index carries
/// a thumbnail of it, and a pack or an index entry without one is valid and reads as no cover.
@Suite("PackCover")
@MainActor
struct PackCoverTests {
    @Test("a pack with a cover names its file, workflow, seed and model, and its LICENSE credits it as an illustration")
    func packWithCover() throws {
        let root = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let pack = try PackSetTests.install("test-pack", root: root)

        let cover = try #require(pack.cover)
        #expect(cover == PackCover(file: "cover.avif", workflowVersion: "set-cover@1 cover-prompts@1", seed: 2_471_396_767, model: "FLUX.3 Image Klein"))
        let url = try #require(pack.coverURL)
        #expect(Self.pixelSize(of: url) == CGSize(width: 1536, height: 864), "AVIF decodes on the phone")
        #expect(pack.info.licenseText.contains("Set cover"))
        #expect(pack.info.licenseText.contains("AI illustration, not a photograph"))
        #expect(pack.info.licenseText.contains("workflow set-cover@1 cover-prompts@1, seed 2471396767"))
    }

    @Test("a pack without a cover is valid: schemas 2 and 3, a schema-4 pack built before covers, and an empty cover table")
    func packsWithoutCover() throws {
        for resource in ["test-pack-schema2", "test-pack-schema3"] {
            let root = try Fixtures.temporaryFolder()
            defer { try? FileManager.default.removeItem(at: root) }
            let pack = try PackSetTests.install(resource, root: root)
            #expect(pack.cover == nil && pack.coverURL == nil, "\(resource)")
        }
        for statement in ["DROP TABLE cover", "DELETE FROM cover"] {
            let root = try Fixtures.temporaryFolder()
            defer { try? FileManager.default.removeItem(at: root) }
            let installed = try PackSetTests.install("test-pack", root: root)
            var database: OpaquePointer?
            #expect(sqlite3_open(installed.directory.appending(path: "pack.sqlite").path(percentEncoded: false), &database) == SQLITE_OK)
            #expect(sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK)
            sqlite3_close(database)
            let pack = try SpeciesPack.open(directory: installed.directory)
            #expect(pack.info.schemaVersion == 4 && pack.species.count == 2, "\(statement)")
            #expect(pack.cover == nil && pack.coverURL == nil, "\(statement)")
        }
    }

    @Test("an index entry carries the cover's thumbnail and credit; one without, or with an unreadable cover, still decodes")
    func indexThumbnail() throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        let json = """
        {"packs": [
          {"id": "us-ca-sd", "name": "San Diego", "version": 5, "url": "https://example.com/sd.zip", "sha256": "ab", "byteCount": 10,
           "cover": {"thumbnail": "\(jpeg.base64EncodedString())", "width": 480, "height": 270, "model": "FLUX.3 Image Klein",
                     "workflowVersion": "set-cover@1 cover-prompts@1", "seed": 259791541}},
          {"id": "us-ca-bay", "name": "SF Bay Area", "version": 2, "url": "https://example.com/bay.zip", "sha256": "cd", "byteCount": 5},
          {"id": "odd", "name": "Odd", "version": 1, "url": "https://example.com/odd.zip", "sha256": "ef", "byteCount": 5,
           "cover": {"thumbnail": "not base64!", "width": "wide"}}
        ]}
        """

        let index = try PackIndex.decode(from: Data(json.utf8))

        let cover = try #require(index.packs[0].cover)
        #expect(cover.thumbnail == jpeg)
        #expect((cover.width, cover.height, cover.seed) == (480, 270, 259_791_541))
        #expect(cover.model == "FLUX.3 Image Klein" && cover.workflowVersion == "set-cover@1 cover-prompts@1")
        #expect(index.packs[1].cover == nil)
        #expect(index.packs[2].cover == nil && index.packs[2].id == "odd", "a cover this build can't read costs only the cover")
        #expect(try PackIndex.decode(from: JSONEncoder().encode(index)) == index, "the cached index keeps its covers")
    }

    @Test("the library shows a set's full cover from its pack, else the index's thumbnail, else none")
    func libraryCover() async throws {
        let root = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let thumbnail = PackIndexCover(
            thumbnail: Data([0xFF, 0xD8]), width: 480, height: 270, model: "FLUX.3 Image Klein", workflowVersion: "set-cover@1 cover-prompts@1", seed: 7
        )
        let zip = try Fixtures.testPackZip()
        let plain = try Fixtures.descriptor(for: zip, version: 1)
        let descriptor = PackDescriptor(
            id: plain.id, name: plain.name, version: plain.version, url: plain.url, sha256: plain.sha256, byteCount: plain.byteCount, cover: thumbnail
        )
        let elsewhere = PackDescriptor(id: "us-ca-sd", name: "San Diego", version: 1, url: zip, sha256: plain.sha256, byteCount: 1, cover: thumbnail)
        let indexURL = root.appending(path: "index.json")
        try JSONEncoder().encode(PackIndex(packs: [descriptor, elsewhere])).write(to: indexURL)
        let library = PackLibrary(
            bundled: try SpeciesPack.bundled(), storage: PackStorage(directory: root.appending(path: "Packs")), indexURL: indexURL, availableCapacity: { nil },
            bundledCovers: .none
        )
        await library.refreshIndex()

        #expect(library.cover(setID: "test-pack") == .thumbnail(thumbnail), "before the download")
        #expect(library.cover(setID: "us-ca-sd") == .thumbnail(thumbnail))
        #expect(library.cover(setID: "nowhere") == nil)

        await library.download(descriptor)

        guard case let .pack(cover, url) = library.cover(setID: "test-pack") else {
            Issue.record("the downloaded pack's full cover")
            return
        }
        #expect(cover.file == "cover.avif" && FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        #expect(library.cover(setID: "test-pack")?.credit == "AI illustration: FLUX.3 Image Klein, set-cover@1 cover-prompts@1, seed 2471396767")
    }

    @Test("the five approved covers ship with the app at full size, each with its credit")
    func shippedCovers() throws {
        for id in ["us-ca-la", "us-ca-sd", "us-ca-bay", "us-ca-desert", "us-fl-orlando"] {
            guard case let .bundled(cover, url) = BundledCovers.shipped.cover(setID: id) else {
                Issue.record("\(id) has no bundled cover")
                continue
            }
            #expect(Self.pixelSize(of: url) == CGSize(width: 1536, height: 864), "\(id)")
            #expect(cover.model == "FLUX.3 Image Klein" && cover.workflowVersion == "set-cover@1 cover-prompts@1", "\(id)")
        }
        #expect(BundledCovers.shipped.cover(setID: "us-tx-houston") == nil)
    }

    @Test("a bundled cover comes before the pack's and the index's, so the painting needs neither the download nor a connection")
    func bundledFirst() async throws {
        let root = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = try Fixtures.testPackZip()
        let plain = try Fixtures.descriptor(for: zip, version: 1)
        let thumbnail = PackIndexCover(thumbnail: Data([0xFF, 0xD8]), width: 480, height: 270, model: "FLUX.3 Image Klein", workflowVersion: "set-cover@1 cover-prompts@1", seed: 7)
        let descriptor = PackDescriptor(id: plain.id, name: plain.name, version: plain.version, url: plain.url, sha256: plain.sha256, byteCount: plain.byteCount, cover: thumbnail)
        let indexURL = root.appending(path: "index.json")
        try JSONEncoder().encode(PackIndex(packs: [descriptor])).write(to: indexURL)
        let own = SetCover.bundled(PackCover(file: "test-pack.jpg", workflowVersion: "set-cover@1 cover-prompts@1", seed: 9, model: "FLUX.3 Image Klein"), root.appending(path: "test-pack.jpg"))
        let library = PackLibrary(
            bundled: try SpeciesPack.bundled(), storage: PackStorage(directory: root.appending(path: "Packs")), indexURL: indexURL, availableCapacity: { nil },
            bundledCovers: BundledCovers(covers: ["test-pack": own])
        )

        #expect(library.cover(setID: "test-pack") == own, "before the index, offline")
        await library.refreshIndex()
        #expect(library.cover(setID: "test-pack") == own, "over the index's thumbnail")
        await library.download(descriptor)
        #expect(library.cover(setID: "test-pack") == own, "over the pack's")
        #expect(own.credit == "AI illustration: FLUX.3 Image Klein, set-cover@1 cover-prompts@1, seed 9")
    }

    private static func pixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: width, height: height)
    }
}
