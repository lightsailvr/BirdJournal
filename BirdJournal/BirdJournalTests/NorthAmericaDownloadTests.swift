import Album
import Foundation
import Identification
import Pack
import SwiftData
import Testing
@testable import BirdJournal

// Issue #215 (of #206): the North America pack on a phone as a download, beside the bundled Los Angeles pack. A bird found
// in Chicago, which no regional set takes, sews a Continental patch with its ceremony, its collector number among the set's
// 300 and "in North America"; the same bird found in Griffith Park still sews its Citrus patch, since the smaller set wins.
//
// The pack here is a stand-in (`north-america-stand-in.zip` among the Pack tests' fixtures, written by
// `packbuilder/tests/make_fixture_pack.py`): the committed set, its 300 birds and its boundary, with two of its birds and
// drawn patches. The pack's own paintings wait for the maintainer's review and are in no test.
@Suite("North America as a download beside the bundled pack", .serialized)
@MainActor
struct NorthAmericaDownloadTests {
    static let setID = "north-america"
    static let chicago = LocationFix.fix(latitude: 41.8781, longitude: -87.6298, accuracy: 10, at: Date(timeIntervalSince1970: 1_790_000_000))
    static let griffith = CaptureWhenIdleTests.griffith
    static let robin = NameableBird(speciesID: "Turdus migratorius_American Robin", scientificName: "Turdus migratorius", commonName: "American Robin", isInFieldGuide: true)

    /// The stand-in pack as an index would list it, its zip on this Mac's disk.
    static func standIn() throws -> PackDescriptor {
        let zip = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "BirdJournalKit/Tests/PackTests/Fixtures/north-america-stand-in.zip")
        let size = try #require(try FileManager.default.attributesOfItem(atPath: zip.path(percentEncoded: false))[.size] as? Int)
        return PackDescriptor(id: setID, name: "North America", version: 1, url: zip, sha256: try PackStorage.sha256(of: zip), byteCount: size, speciesCount: 2, schemaVersion: 5)
    }

    /// A phone with the bundled pack and nothing downloaded: its packs, its album, and the coordinator a capture is named
    /// through, placing sightings among the sets of the packs on the phone as the app does.
    struct Phone {
        let root = URL.temporaryDirectory.appending(path: "NorthAmericaDownload-\(UUID().uuidString)", directoryHint: .isDirectory)
        let library: PackLibrary
        let album: ModelContainer
        let run: ListeningCoordinator
        let location = HeldLocationProvider()

        @MainActor
        init() throws {
            library = PackLibrary(
                bundled: try SpeciesPack.bundled(), storage: PackStorage(directory: root.appending(path: "Packs", directoryHint: .isDirectory)),
                indexURL: root.appending(path: "missing.json"), availableCapacity: { nil }
            )
            album = try AlbumSchema.makeContainer(inMemory: true)
            let recorder = SightingRecorder(container: album, frames: FrameStore(directory: root.appending(path: "Frames", directoryHint: .isDirectory)), rarity: nil)
            recorder.sets = { [library] in library.cardSets }
            let sightings = RunSightings(recorder: recorder)
            let phone = ListeningSession(
                loadEngine: { IdentificationEngine(model: ScriptedBirdModel(), occurrenceModel: SpyOccurrence()) },
                makeSource: { ManualAudioSource() },
                location: ScriptedLocationProvider([.denied])
            )
            let glasses = GlassesListeningSession(recorder: recorder, sightings: sightings, loadEngine: { IdentificationEngine(model: ScriptedBirdModel(), occurrenceModel: SpyOccurrence()) }, location: ScriptedLocationProvider([.denied]))
            run = ListeningCoordinator(
                phone: phone, glasses: glasses, sightings: sightings, levels: LevelSink(), defaultSource: .phone,
                defaults: UserDefaults(suiteName: "north-america-download-\(UUID().uuidString)")!, captureLocation: location
            )
        }

        /// Downloads the stand-in as the packs screen would, from its zip.
        @MainActor
        func downloadNorthAmerica() async throws {
            let descriptor = try NorthAmericaDownloadTests.standIn()
            await library.download(descriptor)
            try #require(library.pack(id: descriptor.id) != nil, "the stand-in did not install: \(library.status(of: descriptor))")
        }

        /// Takes a photo with no run where the phone is and names it a robin: the add, as "Capture a sighting" makes it.
        @MainActor
        func findARobin(at fix: LocationFix) async throws -> RunSightings.Addition {
            run.isCapturing = true
            location.send(fix)
            let deadline = ContinuousClock.now + .seconds(30)
            while run.capturePlace == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            let unnamed = try #require(run.capture(CaptureWhenIdleTests.photo()))
            run.isCapturing = false
            return try #require(run.name(unnamed, as: NorthAmericaDownloadTests.robin))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test("with North America downloaded, a robin found in Chicago sews a Continental patch: its ceremony, No. 226 of the set's 300, and \"in North America\"")
    func aBirdFoundInChicagoSewsAContinentalPatch() async throws {
        let phone = try Phone()
        defer { phone.remove() }
        try await phone.downloadNorthAmerica()
        #expect(Set(phone.library.cardSets.map(\.id)) == [PackIndex.bundledPackID, Self.setID], "both packs' sets take sightings")

        let addition = try await phone.findARobin(at: Self.chicago)

        #expect(addition.sewsPatch, "its first sighting there: the patch is sewn")
        #expect(addition.placement == .numbered(setID: Self.setID, setName: "North America", edition: "Continental edition", number: 226, total: 300))
        #expect(addition.placement.collectorNumber == "226/300")
        let reveal = try #require(phone.run.reveal, "the stitch-in and the new patch's page")
        #expect(reveal.addition == addition && !reveal.hasPlayed, "the ceremony plays at the add")
        #expect(reveal.eyebrow == "New patch, Continental edition")
        #expect(reveal.title == "Your first American Robin in North America")
        #expect(phone.run.acknowledgment?.text == "Your first American Robin in North America")
        #expect(CardHeading.accessibilityText(placement: addition.placement) == ["Continental edition", "number 226 of 300 in North America"])

        // The patch is the download's own painting, wide as the edition is, and the edition is drawn as Continental.
        let art = try #require(phone.library.patch(scientificName: "Turdus migratorius", setID: Self.setID))
        #expect(art.pack.info.id == Self.setID)
        #expect(abs(Double(art.patch.width) / Double(art.patch.height) - 1.42) < 0.02, "\(art.patch.width) x \(art.patch.height)")
        #expect("\(PatchEdition.of(setID: addition.placement.setID).shape)" == "wideRectangle")
    }

    @Test("a robin found in Griffith Park, which both sets list, still sews its Citrus patch from the Los Angeles pack")
    func aBirdBothSetsListFoundInLosAngelesStillSewsCitrus() async throws {
        let phone = try Phone()
        defer { phone.remove() }
        try await phone.downloadNorthAmerica()
        let both = phone.library.setsTakingSightings.filter { $0.species.contains { $0.scientificName == "Turdus migratorius" } }
        #expect(Set(both.map(\.id)) == [PackIndex.bundledPackID, Self.setID], "the robin is on both lists")

        let addition = try await phone.findARobin(at: Self.griffith)

        #expect(addition.sewsPatch)
        #expect(addition.placement.setID == PackIndex.bundledPackID, "the smaller set that lists it takes it: \(addition.placement)")
        #expect(addition.placement.editionLabel == "Citrus edition")
        let reveal = try #require(phone.run.reveal)
        #expect(reveal.eyebrow == "New patch, Citrus edition")
        #expect(reveal.title == "Your first American Robin in Los Angeles")
        let art = try #require(phone.library.patch(scientificName: "Turdus migratorius", setID: addition.placement.setID))
        #expect(art.pack.info.id == PackIndex.bundledPackID, "painted by the Los Angeles pack, not the continent's")
        #expect(abs(Double(art.patch.width) / Double(art.patch.height) - 1) < 0.1, "Citrus is round: \(art.patch.width) x \(art.patch.height)")
    }

    @Test("the two finds are two patches, one in each set, and the continent's set counts one of its 300 sewn")
    func oneBirdTwoPatches() async throws {
        let phone = try Phone()
        defer { phone.remove() }
        try await phone.downloadNorthAmerica()
        let store = CollectionStore(container: phone.album, sets: { [library = phone.library] in library.cardSets })

        let chicago = try await phone.findARobin(at: Self.chicago)
        phone.run.finishCeremony()
        phone.run.dismissReveal()
        let griffith = try await phone.findARobin(at: Self.griffith)

        #expect(store.collection.patch(of: chicago.identifier)?.placement.setID == Self.setID)
        #expect(store.collection.patch(of: griffith.identifier)?.placement.setID == PackIndex.bundledPackID)
        #expect(store.collection.patchCount == 2)
        #expect(store.collection.progress(of: Self.setID) == SetProgress(setID: Self.setID, name: "North America", collected: 1, total: 300))
    }
}
