import Album
import Foundation
import Pack
import SwiftData
import Testing
@testable import BirdJournal

/// Issue #207 (of #206): the collection places sightings among the sets whose pack is on the phone, while the Atlas, the
/// place and a friend's find still read every set the phone knows. The bundled pack's own files stand in for a download
/// here, in a library with no bundled pack, so a field guide can come and go.
@Suite("Sets on the phone, in the app", .serialized)
@MainActor
struct PlacementOnThePhoneTests {
    static let griffith = Coordinate(latitude: 34.1365, longitude: -118.2942, accuracy: 10)
    static let joshuaTree = Coordinate(latitude: 33.8734, longitude: -115.9010, accuracy: 10)
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// A phone's pack storage and album in a temporary folder.
    struct Phone {
        let root = URL.temporaryDirectory.appending(path: "SetsOnThePhone-\(UUID().uuidString)", directoryHint: .isDirectory)
        let storage: PackStorage
        let album: ModelContainer
        /// The pack whose files `download()` copies in: the one that ships in the app.
        let fieldGuide: SpeciesPack

        init() throws {
            storage = PackStorage(directory: root.appending(path: "Packs", directoryHint: .isDirectory))
            album = try AlbumSchema.makeContainer(inMemory: true)
            fieldGuide = try SpeciesPack.bundled()
        }

        /// A library with no bundled pack and the index out of reach: its packs are the downloads, and it knows the sets that
        /// shipped with the app.
        @MainActor
        func library() -> PackLibrary {
            PackLibrary(bundled: nil, storage: storage, indexURL: root.appending(path: "missing.json"), availableCapacity: { nil })
        }

        /// Puts the field guide in the storage as `PackStorage.install` leaves a download.
        func download() throws {
            let folder = storage.url(for: fieldGuide.info.id)
            try FileManager.default.createDirectory(at: storage.directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fieldGuide.directory, to: folder)
            let descriptor = PackDescriptor(
                id: fieldGuide.info.id, name: fieldGuide.info.name, version: fieldGuide.info.version, url: URL(string: "https://example.invalid/pack.zip")!,
                sha256: "", byteCount: 1, speciesCount: fieldGuide.species.count
            )
            try JSONEncoder().encode(descriptor).write(to: folder.appending(path: "installed.json"))
        }

        /// Two sightings of the field guide's first bird in Griffith Park, a minute apart; the earlier one first.
        @MainActor
        func addTwoSightings() throws -> [Sighting] {
            let bird = try #require(fieldGuide.species.first)
            let sightings = [0.0, 60.0].map { seconds in
                Sighting(speciesID: "\(bird.scientificName)_\(bird.commonName)", confirmedAt: PlacementOnThePhoneTests.start.addingTimeInterval(seconds), location: PlacementOnThePhoneTests.griffith, soundConfidence: 0.8, source: .phone)
            }
            sightings.forEach(album.mainContext.insert)
            try album.mainContext.save()
            return sightings
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test("a sighting in a set whose field guide isn't on the phone is Uncharted; with the field guide it is that set's patch, with the same count and sewn date")
    func aDownloadTakesItsSightings() throws {
        let phone = try Phone()
        defer { phone.remove() }
        let sightings = try phone.addTwoSightings()
        let setID = phone.fieldGuide.info.id

        let without = phone.library()
        #expect(without.cardSets.isEmpty, "no pack on the phone, so no set takes a sighting")
        #expect(without.set(id: setID) != nil, "though the Atlas knows the set")
        let before = CardCollection(sightings: sightings, sets: without.cardSets)
        let uncharted = try #require(before.patch(of: sightings[1].identifier))
        #expect(uncharted.placement == .uncharted)
        #expect(uncharted.count == 2 && uncharted.sewn.identifier == sightings[0].identifier)

        try phone.download()
        let with = phone.library()
        #expect(with.cardSets.map(\.id) == [setID])
        let after = CardCollection(sightings: sightings, sets: with.cardSets)
        let patch = try #require(after.patch(of: sightings[1].identifier))
        #expect(patch.placement.setID == setID, "the download's set takes them")
        #expect(after.patchCount == 1 && patch.count == 2)
        #expect(patch.sewn.identifier == sightings[0].identifier && patch.sewn.confirmedAt == Self.start, "sewn when it was first found")
        #expect(with.patch(scientificName: patch.scientificName, setID: setID) != nil, "with the edition's own patch art")
    }

    @Test("deleting a download moves its sightings on at once; the Atlas still lists the set, with none of its birds sewn")
    func deletingADownloadHandsItsSightingsOn() async throws {
        let phone = try Phone()
        defer { phone.remove() }
        let sightings = try phone.addTwoSightings()
        try phone.download()
        let library = phone.library()
        let setID = phone.fieldGuide.info.id
        let store = CollectionStore(container: phone.album, sets: { library.cardSets })
        #expect(store.collection.patch(of: sightings[0].identifier)?.placement.setID == setID)
        let set = try #require(library.set(id: setID))
        #expect(store.collection.progress(of: set) == SetProgress(setID: setID, name: set.name, collected: 1, total: set.species.count))

        try library.remove(id: setID)

        for _ in 0..<100 where store.collection.patch(of: sightings[0].identifier)?.placement != .uncharted {
            try await Task.sleep(for: .milliseconds(20))
        }
        let patch = try #require(store.collection.patch(of: sightings[0].identifier))
        #expect(patch.placement == .uncharted, "no other set on the phone takes it")
        #expect(patch.count == 2 && patch.sewn.identifier == sightings[0].identifier)
        #expect(try phone.album.mainContext.fetch(FetchDescriptor<Sighting>()).count == 2, "the sightings are as they were")
        let known = try #require(library.set(id: setID), "the Atlas still lists the set")
        #expect(store.collection.progress(of: known) == SetProgress(setID: setID, name: known.name, collected: 0, total: known.species.count), "by its own name and size, not as a set nobody knows")
    }

    @Test("a place inside a set whose field guide isn't on the phone is still that set's place, with none of its birds sewn there")
    func thePlaceIsAKnownSet() throws {
        let phone = try Phone()
        defer { phone.remove() }
        let library = PackLibrary(bundled: phone.fieldGuide, storage: phone.storage, indexURL: phone.root.appending(path: "missing.json"), availableCapacity: { nil })
        let desert = try #require(library.set(id: "us-ca-desert"), "a set that shipped with the app")
        #expect(library.pack(id: desert.id) == nil)
        // A desert bird no set on the phone lists, found in the desert.
        let onPhone = Set(library.setsTakingSightings.flatMap(\.species).map(\.scientificName))
        let bird = try #require(desert.species.first { !onPhone.contains($0.scientificName) })
        let entry = CardCollection.Entry(identifier: UUID(), speciesID: "\(bird.scientificName)_\(bird.commonName)", confirmedAt: Self.start, location: Self.joshuaTree)
        let collection = CardCollection([entry], sets: library.cardSets)

        #expect(collection.placement(of: entry.identifier) == .uncharted, "the desert set takes nothing until its field guide is on the phone")
        #expect(LocalSet.choose(coordinate: Self.joshuaTree, in: collection, among: library.knownCardSets) == desert.id, "the painting and Your local set still follow the place")
        let local = try #require(LocalSet(setID: desert.id, library: library, collection: collection))
        #expect(local.progress == SetProgress(setID: desert.id, name: desert.name, collected: 0, total: desert.species.count))
        #expect(!local.isOnPhone)
        #expect(LocalSet(setID: phone.fieldGuide.info.id, library: library, collection: collection)?.isOnPhone == true)
    }

    @Test("a friend's find in an edition whose field guide isn't on the phone still reads its edition")
    func aKnownSetsEdition() throws {
        let phone = try Phone()
        defer { phone.remove() }
        let library = phone.library()
        #expect(library.cardSets.isEmpty)
        #expect(library.editionLabel(setID: "us-ca-desert") == library.set(id: "us-ca-desert")?.edition.name)
        #expect(library.editionLabel(setID: "us-ca-desert")?.hasSuffix("edition") == true)
        #expect(library.editionLabel(setID: nil) == nil)
    }

    @Test("a set's page says what its field guide's absence means: birds found there aren't sewn into the set until it is downloaded")
    func notOnPhoneWords() {
        for canDownload in [true, false] {
            let words = SetView.notOnPhoneText(canDownload: canDownload)
            #expect(words.contains("aren't sewn into this set"), "\(words)")
            #expect(!words.contains("either way"), "\(words)")
        }
    }
}
