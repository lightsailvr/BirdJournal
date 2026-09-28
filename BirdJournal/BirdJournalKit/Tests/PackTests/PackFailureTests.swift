import Foundation
import Testing
@testable import Pack

/// What the packs screen says when a download cannot happen or fails (issue #28): not enough space is refused before
/// a byte moves, a working install survives a failed update, and the messages name the cause and the remedy.
@Suite("Pack failures")
@MainActor
struct PackFailureTests {
    @Test("a download that would not fit is refused before it starts, and the message says how much is needed")
    func refusesWithoutSpace() async throws {
        let root = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Fixtures.library(root: root, availableCapacity: { 1 << 20 })
        await library.refreshIndex()
        let descriptor = try #require(library.available.first)

        await library.download(descriptor)

        guard case .failed(let message) = library.status(of: descriptor) else {
            Issue.record("expected a failed status, got \(library.status(of: descriptor))")
            return
        }
        #expect(message.hasPrefix("Not enough space on this iPhone"))
        #expect(message.contains("1 MB is available"))
        #expect(library.storage.installed().isEmpty)

        library.dismissFailure(id: descriptor.id)
        #expect(library.status(of: descriptor) == .notInstalled)
    }

    @Test("an update whose zip does not unpack leaves the installed version in place")
    func failedUpdateKeepsInstall() async throws {
        let root = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = try Fixtures.testPackZip()
        let storage = PackStorage(directory: root.appending(path: "Packs"))
        let installed = try storage.install(zip: zip, as: try Fixtures.descriptor(for: zip, version: 1))
        // Version 2 in the index points at a zip that is not a pack; its checksum matches itself, so the failure is
        // in unpacking, after the checksum, where an update is most likely to be interrupted.
        let broken = root.appending(path: "broken.zip")
        try Data("not a zip at all".utf8).write(to: broken)
        let library = try Fixtures.library(root: root, indexVersion: 2, zip: broken)
        await library.refreshIndex()
        let descriptor = try #require(library.index?.descriptor(id: "test-pack"))
        #expect(library.status(of: descriptor) == .updateAvailable(installed: 1, available: 2))

        await library.download(descriptor)

        guard case .failed = library.status(of: descriptor) else {
            Issue.record("expected a failed status, got \(library.status(of: descriptor))")
            return
        }
        #expect(library.pack(id: "test-pack")?.species.count == 2, "the working pack is still there")
        #expect(storage.installed().map(\.descriptor.version) == [1])
        #expect(try FileManager.default.contentsOfDirectory(atPath: storage.directory.path(percentEncoded: false)).sorted() == ["test-pack"], "no staging or set-aside folder is left")
        #expect(PackStorage.diskUsage(of: installed.pack.directory) > 0)
    }

    @Test("failure messages name the cause and what to do")
    func messages() {
        #expect(PackLibrary.message(for: URLError(.notConnectedToInternet)) == "No internet connection. Connect to Wi‑Fi or cellular data and try again.")
        #expect(PackLibrary.message(for: URLError(.networkConnectionLost)) == "The connection dropped before the download finished. Try again.")
        #expect(PackLibrary.message(for: URLError(.timedOut)) == "The download timed out. Try again.")
        #expect(PackLibrary.message(for: CocoaError(.fileWriteOutOfSpace)).hasPrefix("This iPhone ran out of space"))
        #expect(PackLibrary.message(for: PackDownloadError.httpStatus(503)) == "The pack server answered 503. Try again later.")
        #expect(PackLibrary.spaceNeeded(for: PackDescriptor(id: "x", name: "X", version: 1, url: URL(string: "https://example.com")!, sha256: "", byteCount: 1_000)) == 2_000 + PackLibrary.storageHeadroom)
    }
}
