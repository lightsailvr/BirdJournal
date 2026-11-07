import Album
import Foundation
import Identification
import Observation
import Synchronization
import SwiftData
import SwiftUI
import Testing
@testable import BirdJournal

// Issue #150, slice 4: the screens read one kept collection, the engine loads ahead of Start, and a Guild draws what was
// last known. The package's `CardCollectionCacheTests` hold that a kept collection answers as a fresh one does; these hold
// that the app keeps it fed.

@Suite("The collection store", .serialized)
@MainActor
struct CollectionStoreTests {
    nonisolated private static let griffith = Coordinate(latitude: 34.1365, longitude: -118.2942, accuracy: 15)
    nonisolated private static let finch = "Haemorhous mexicanus_House Finch"
    private static let phoebe = "Sayornis nigricans_Black Phoebe"
    private static let sets = [CardSet(id: "la", name: "Los Angeles", edition: "Griffith", species: ["Haemorhous mexicanus", "Sayornis nigricans"], regions: [
        CardSet.Region(name: "LA", polygons: [[[
            CardSet.Point(longitude: -119, latitude: 33), CardSet.Point(longitude: -117, latitude: 33),
            CardSet.Point(longitude: -117, latitude: 35), CardSet.Point(longitude: -119, latitude: 35),
            CardSet.Point(longitude: -119, latitude: 33),
        ]]]),
    ])]

    nonisolated final class Flag: @unchecked Sendable {
        var isSet = false
    }

    /// The sets the phone knows, as a pack download changes them.
    @Observable
    final class KnownSets {
        var sets: [CardSet] = []
    }

    private func sighting(_ species: String = Self.finch, minutes: Double = 0, at location: Coordinate? = griffith) -> Sighting {
        Sighting(speciesID: species, confirmedAt: Date(timeIntervalSince1970: 1_800_000_000 + minutes * 60), location: location, soundConfidence: 0.7, source: .phone)
    }

    private func fresh(_ container: ModelContainer, sets: [CardSet]) throws -> CardCollection {
        CardCollection(sightings: try container.mainContext.fetch(FetchDescriptor<Sighting>()), sets: sets)
    }

    @Test("it starts from the album, and every save reaches it before the save returns")
    func followsSaves() throws {
        let container = try AlbumSchema.makeContainer(inMemory: true)
        let context = container.mainContext
        let first = sighting()
        context.insert(first)
        try context.save()

        let store = CollectionStore(container: container, sets: { Self.sets })
        #expect(store.collection == (try fresh(container, sets: Self.sets)))
        #expect(store.collection.patchCount == 1)

        // An add through the app's own recorder path: a save on the main context.
        context.insert(sighting(Self.phoebe, minutes: 5))
        try context.save()
        #expect(store.collection.patchCount == 2, "there as soon as the save returns")
        #expect(store.collection == (try fresh(container, sets: Self.sets)))

        // A repeat adds to its patch.
        context.insert(sighting(minutes: 9))
        try context.save()
        #expect(store.collection.patch(of: first.identifier)?.count == 2)

        // A removal unpicks what it should.
        context.delete(first)
        try context.save()
        #expect(store.collection.patch(of: first.identifier) == nil)
        #expect(store.collection == (try fresh(container, sets: Self.sets)))
    }

    @Test("a save off the main actor reaches it too")
    func followsOtherContexts() async throws {
        let container = try AlbumSchema.makeContainer(inMemory: true)
        let store = CollectionStore(container: container, sets: { Self.sets })
        let task = Task.detached {
            let background = ModelContext(container)
            background.insert(Sighting(speciesID: Self.finch, confirmedAt: Date(timeIntervalSince1970: 1_800_000_000), location: Self.griffith, soundConfidence: 0.7, source: .phone))
            try background.save()
        }
        try await task.value
        for _ in 0..<100 where store.collection.patchCount == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.collection.patchCount == 1)
    }

    @Test("a save that changes nothing it reads leaves it alone, so no screen draws again")
    func aNoteChangesNothing() async throws {
        let container = try AlbumSchema.makeContainer(inMemory: true)
        let context = container.mainContext
        let first = sighting()
        context.insert(first)
        try context.save()
        let store = CollectionStore(container: container, sets: { Self.sets })

        let changed = Flag()
        withObservationTracking { _ = store.collection } onChange: { changed.isSet = true }
        first.note = "On the wire by the pond"
        try context.save()
        #expect(!changed.isSet, "a note isn't in the collection")

        first.location = nil
        try context.save()
        #expect(changed.isSet, "a place is")
        #expect(store.collection.unchartedPatches.count == 1)
    }

    @Test("another album's save isn't its business")
    func anotherAlbum() throws {
        let container = try AlbumSchema.makeContainer(inMemory: true)
        let other = try AlbumSchema.makeContainer(inMemory: true)
        let store = CollectionStore(container: container, sets: { Self.sets })
        other.mainContext.insert(sighting())
        try other.mainContext.save()
        #expect(store.collection.patchCount == 0)
    }

    @Test("a newly known set pulls older sightings in")
    func followsSets() async throws {
        let container = try AlbumSchema.makeContainer(inMemory: true)
        container.mainContext.insert(sighting())
        try container.mainContext.save()
        let known = KnownSets()
        let store = CollectionStore(container: container, sets: { known.sets })
        #expect(store.collection.unchartedPatches.count == 1)

        known.sets = Self.sets
        for _ in 0..<100 where store.collection.progress(of: "la").collected == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.collection.progress(of: "la").collected == 1)
        #expect(store.collection == (try fresh(container, sets: Self.sets)))

        // And it keeps watching.
        known.sets = []
        for _ in 0..<100 where store.collection.progress(of: "la").total != 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.collection.unchartedPatches.count == 1)
    }
}

@Suite("Loading the engine ahead of a run")
@MainActor
struct WarmLoaderTests {
    /// Counts the loads, and can fail or hold one.
    nonisolated final class Loads: Sendable {
        private let state = Mutex(State())
        private struct State {
            var count = 0
            var failing = false
        }

        var count: Int { state.withLock { $0.count } }

        func setFailing(_ failing: Bool) {
            state.withLock { $0.failing = failing }
        }

        func load() throws -> Int {
            try state.withLock {
                $0.count += 1
                if $0.failing { throw CancellationError() }
                return $0.count
            }
        }
    }

    private static let pressure = Notification.Name("speed-tests-memory-warning")

    @Test("warming loads it once, and Start gets the warmed one")
    func warmThenValue() async throws {
        let loads = Loads()
        let loader = WarmLoader<Int>(dropsOn: Self.pressure, center: NotificationCenter()) { try loads.load() }
        loader.warm()
        loader.warm()
        #expect(try await loader.value() == 1)
        #expect(try await loader.value() == 1)
        #expect(loads.count == 1)
    }

    @Test("without a warm-up Start still loads it, once")
    func valueAlone() async throws {
        let loads = Loads()
        let loader = WarmLoader<Int>(dropsOn: Self.pressure, center: NotificationCenter()) { try loads.load() }
        async let first = loader.value()
        async let second = loader.value()
        let values = try await [first, second]
        #expect(values == [1, 1])
    }

    @Test("memory pressure drops it, and the next asking loads it again")
    func pressureDrops() async throws {
        let loads = Loads()
        let center = NotificationCenter()
        let loader = WarmLoader<Int>(dropsOn: Self.pressure, center: center) { try loads.load() }
        #expect(try await loader.value() == 1)
        center.post(name: Self.pressure, object: nil)
        #expect(try await loader.value() == 2)
        loader.warm()
        #expect(try await loader.value() == 2, "kept again once loaded")
    }

    @Test("memory pressure during a load doesn't start a second one")
    func pressureDuringALoad() async throws {
        let loads = Loads()
        let center = NotificationCenter()
        let gate = DispatchSemaphore(value: 0)
        let loader = WarmLoader<Int>(dropsOn: Self.pressure, center: center) {
            gate.wait()
            return try loads.load()
        }
        loader.warm()
        center.post(name: Self.pressure, object: nil)
        async let value = loader.value()
        gate.signal()
        #expect(try await value == 1)
        #expect(loads.count == 1)
    }

    @Test("a failed load is forgotten, so the next start tries again, whether Start or the warm-up failed")
    func failuresRetry() async throws {
        let loads = Loads()
        loads.setFailing(true)
        let loader = WarmLoader<Int>(dropsOn: Self.pressure, center: NotificationCenter()) { try loads.load() }
        await #expect(throws: CancellationError.self) { try await loader.value() }
        // Forgotten a beat after it fails, so a failed load may answer once more.
        for _ in 0..<200 where loads.count < 2 {
            loader.warm()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(loads.count >= 2, "the warm-up tried again")
        loads.setFailing(false)
        var value = try? await loader.value()
        for _ in 0..<200 where value == nil {
            try await Task.sleep(for: .milliseconds(10))
            value = try? await loader.value()
        }
        #expect(value == loads.count, "and the next asking loaded it")
    }

    @Test("Listen asks for the engine when it appears")
    func listenWarms() async throws {
        let harness = try ScreenAccessibilityTests.Harness()
        var asked = 0
        _ = try await ScreenAccessibilityTests.walk(ListenView().environment(\.warmEngine) { asked += 1 }, harness: harness) { _ in asked > 0 }
        #expect(asked == 1)
    }

    @Test("not during a run, which holds its own engine")
    func listenDoesntWarmDuringARun() async throws {
        let harness = try ScreenAccessibilityTests.Harness()
        await harness.run.start()
        #expect(harness.run.state == .listening)
        var asked = 0
        var polls = 0
        _ = try await ScreenAccessibilityTests.walk(ListenView().environment(\.warmEngine) { asked += 1 }, harness: harness) { _ in
            polls += 1
            return polls >= 4  // a second on screen, past the warm-up's wait
        }
        #expect(asked == 0)
        await harness.run.stop()
    }
}

@Suite("Guild screens from what's kept", .serialized)
@MainActor
struct LastKnownGuildScreenTests {
    @Test("Compare stops showing a friend once the server says they're gone, as after a block made elsewhere")
    func compareClearsOnNotFound() async throws {
        let harness = try ScreenAccessibilityTests.Harness()
        let store = harness.circles
        let client = try #require(store.client as? FakeCircleClient)
        await store.refresh()
        let birds = try await store.compare(friendID: "maya")
        #expect(!birds.species.isEmpty)
        try await client.setBlocked(true, accountID: "maya", accessToken: "t")

        let labels = try await ScreenAccessibilityTests.walk(CompareBirdsView(friendID: "maya", friendName: "Maya Ortiz"), harness: harness) { $0.contains("Try again") }
        #expect(labels.contains("Try again"), "\(labels)")
        #expect(!labels.contains { label in birds.species.contains { label.contains($0.commonName) } }, "\(labels)")
    }

    @Test("a birder who didn't start the Guild is still themselves when the account hasn't been read")
    func myRowWithoutTheAccount() async throws {
        let harness = try ScreenAccessibilityTests.Harness()
        let store = harness.circles
        await store.refresh()
        let family = try #require(store.circles.first { $0.name == "Family" })
        #expect(!family.isCreator)
        #expect(harness.account.account == nil)
        try await store.loadDetail(id: family.id)
        let labels = try await ScreenAccessibilityTests.walk(CircleInfoSheet(circleID: family.id) {}, harness: harness) { $0.contains { $0.contains("Pat Birder (you)") } }
        #expect(labels.contains { $0.contains("Pat Birder (you)") }, "\(labels)")
    }
}

@Suite("The Guild placeholder", .serialized)
@MainActor
struct GuildPlaceholderTests {
    @Test("VoiceOver hears Loading once, at the default size and the largest")
    func saysLoadingOnce() async throws {
        let harness = try ScreenAccessibilityTests.Harness(seeded: false)
        for size in [DynamicTypeSize.large, .accessibility5] {
            let labels = try await ScreenAccessibilityTests.walk(PaperList { Section { GuildPlaceholder(rows: 3) } }, harness: harness, typeSize: size) { $0.contains("Loading") }
            #expect(labels.filter { $0 == "Loading" }.count == 1, "\(labels)")
            #expect(!labels.contains { $0.contains("A bird in a Guild") }, "the sample words aren't read: \(labels)")
        }
    }
}
