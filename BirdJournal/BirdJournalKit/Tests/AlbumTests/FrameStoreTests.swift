import Foundation
import Testing
@testable import Album

// Issue #9: the frame captured at confirm time is written beside the album and referenced by a relative path.
@Suite("FrameStore")
struct FrameStoreTests {
    @Test("a written frame comes back from the path the sighting stores, and the folder is created on first use")
    func writeAndResolve() throws {
        let directory = URL.temporaryDirectory.appending(path: "frames-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FrameStore(directory: directory)
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])

        let path = try store.write(jpeg: jpeg)

        #expect(path.hasSuffix(".jpg"))
        #expect(!path.contains("/"), "the path is relative to the store, so the album survives the container moving")
        #expect(try Data(contentsOf: store.url(for: path)) == jpeg)
        #expect(store.url(for: path) == directory.appending(path: path))
    }

    @Test("frames get distinct names by default")
    func distinctNames() throws {
        let directory = URL.temporaryDirectory.appending(path: "frames-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FrameStore(directory: directory)
        let first = try store.write(jpeg: Data([1]))
        let second = try store.write(jpeg: Data([2]))
        #expect(first != second)
    }
}
