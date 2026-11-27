import Foundation
import Testing
@testable import Pack

/// Issue #223 (of #206): a birder standing in a set whose field guide isn't on the phone is offered its download, once per
/// set. Whether it is offered is decided from four facts, with no network and no location fix.
@Suite("A field guide offered where the birder is")
struct FieldGuideOfferTests {
    @Test("standing in a set whose field guide can be downloaded and isn't on the phone, that set is offered")
    func offersThePlacesSet() {
        #expect(FieldGuideOffer.setToOffer(place: "marsh", onPhone: ["home"], downloadable: ["marsh", "dunes"], dismissed: []) == "marsh")
    }

    struct Case: Sendable, CustomTestStringConvertible {
        let testDescription: String
        var place: String? = "marsh"
        var onPhone: Set<String> = ["home"]
        var downloadable: Set<String> = ["marsh", "dunes"]
        var dismissed: Set<String> = []
        let offers: String?
    }

    @Test("every other combination: nothing where the field guide is on the phone, outside every set, after a dismissal, or with nothing to download", arguments: [
        Case(testDescription: "the place's field guide is on the phone", onPhone: ["home", "marsh"], offers: nil),
        Case(testDescription: "at home, in the set that ships with the app", place: "home", offers: nil),
        Case(testDescription: "outside every set", place: nil, offers: nil),
        Case(testDescription: "its offer was dismissed", dismissed: ["marsh"], offers: nil),
        Case(testDescription: "another set's offer was dismissed", dismissed: ["dunes"], offers: "marsh"),
        Case(testDescription: "one dismissed, standing in the other", place: "dunes", dismissed: ["marsh"], offers: "dunes"),
        Case(testDescription: "a set known only from what shipped with the app: nothing to download yet", downloadable: ["dunes"], offers: nil),
        Case(testDescription: "no list of downloads at all", downloadable: [], offers: nil),
        Case(testDescription: "dismissed, then downloaded anyway", onPhone: ["home", "marsh"], dismissed: ["marsh"], offers: nil),
    ])
    func everyCombination(_ row: Case) {
        #expect(FieldGuideOffer.setToOffer(place: row.place, onPhone: row.onPhone, downloadable: row.downloadable, dismissed: row.dismissed) == row.offers)
    }

    /// The library's own facts: the bundled pack on the phone, and an index listing the fixture pack, a set whose pack this
    /// build can't open, and the bundled pack.
    @MainActor
    static func library(root: URL) async throws -> PackLibrary {
        let zip = try Fixtures.testPackZip()
        let bundled = try SpeciesPack.bundled()
        let index = PackIndex(packs: [
            PackDescriptor(id: bundled.info.id, name: bundled.info.name, version: bundled.info.version, url: zip, sha256: "x", byteCount: 1),
            try Fixtures.descriptor(for: zip, version: 1),
            PackDescriptor(id: "test-newer", name: "Newer", version: 1, url: zip, sha256: "x", byteCount: 1, schemaVersion: SpeciesPack.schemaVersion + 1),
        ])
        let indexURL = root.appending(path: "index.json")
        try JSONEncoder().encode(index).write(to: indexURL)
        let library = PackLibrary(bundled: bundled, storage: PackStorage(directory: root.appending(path: "Packs")), indexURL: indexURL, availableCapacity: { nil })
        await library.refreshIndex()
        #expect(library.indexError == nil)
        return library
    }

    @Test("the library offers the place's download as the index lists it, with its size, until the field guide is on the phone")
    @MainActor
    func theLibraryOffersThePlacesDownload() async throws {
        let root = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try await Self.library(root: root)
        let listed = try Fixtures.descriptor(for: Fixtures.testPackZip(), version: 1)
        #expect(listed.byteCount > 0)

        #expect(library.fieldGuideOffer(place: "test-pack", dismissed: []) == listed)
        #expect(library.fieldGuideOffer(place: "test-pack", dismissed: ["test-pack"]) == nil)
        #expect(library.fieldGuideOffer(place: library.bundled?.info.id, dismissed: []) == nil, "the bundled field guide is always on the phone")
        #expect(library.fieldGuideOffer(place: "test-newer", dismissed: []) == nil, "a field guide this build can't open has no Download to offer")
        #expect(library.fieldGuideOffer(place: nil, dismissed: []) == nil)

        await library.download(listed)

        #expect(library.pack(id: "test-pack") != nil)
        #expect(library.fieldGuideOffer(place: "test-pack", dismissed: []) == nil, "it's on the phone")

        try library.remove(id: "test-pack")

        #expect(library.fieldGuideOffer(place: "test-pack", dismissed: []) == listed, "removed and never dismissed, it's offered where the birder is again")
    }
}
