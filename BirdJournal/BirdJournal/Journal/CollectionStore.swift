import Album
import Foundation
import Observation
import OSLog
import SwiftData

/// The birder's collection, kept (issue #150): every screen reads `collection` from here rather than placing every sighting
/// in its set's polygons in its own body. It builds again only when the sightings or the sets change. A save anywhere in the
/// album lands here before the save returns on the main actor, so a screen drawn after an add already reads the new patch.
@Observable
final class CollectionStore {
    private(set) var collection: CardCollection

    @ObservationIgnored private var cache: CardCollectionCache
    @ObservationIgnored private var sets: [CardSet]
    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let readSets: () -> [CardSet]
    @ObservationIgnored private var saves: (any NSObjectProtocol)?
    @ObservationIgnored private var loaded: Bool
    @ObservationIgnored private var revision = 0
    private let log = Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "album")

    /// - Parameter sets: every set the phone knows, read under observation, so a pack download or a new index reaches it.
    init(container: ModelContainer, deferred: Bool = false, sets: @escaping () -> [CardSet]) {
        loaded = !deferred
        self.container = container
        readSets = sets
        #if DEBUG
        let started = ContinuousClock.now
        defer {
            if !deferred { SpeedProbe.refreshed(in: ContinuousClock.now - started); SpeedProbe.built() }
        }
        #endif
        let known = deferred ? [] : sets()
        self.sets = known
        let cache = CardCollectionCache(deferred ? [] : Self.entries(in: container) ?? [], sets: known)
        self.cache = cache
        collection = cache.collection
        if !deferred { watchSets() }
        saves = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) { [weak self, container] note in
            guard (note.object as? ModelContext)?.container === container else { return }
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.refresh() }
            } else {
                Task { @MainActor in self?.refresh() }
            }
        }
    }

    /// Fetches using a background context; only Sendable entries and the finished collection cross actors. A save
    /// during the read invalidates it, so a late snapshot can never overwrite a just-added sighting.
    func loadForLaunch() async throws {
        guard !loaded else { return }
        #if DEBUG
        let started = ContinuousClock.now
        #endif
        let container = container
        while true {
            let generation = revision
            let known = readSets()
            let snapshot = try await Task.detached(priority: .userInitiated) {
                let signposter = OSSignposter(subsystem: "com.matthewcelia.mybirdjournal", category: "launch")
                let state = signposter.beginInterval("Build collection")
                defer { signposter.endInterval("Build collection", state) }
                let context = ModelContext(container)
                let entries = try context.fetch(FetchDescriptor<Sighting>()).map(CardCollection.Entry.init)
                return CardCollectionCache(entries, sets: known)
            }.value
            try Task.checkCancellation()
            guard generation == revision, known == readSets() else { continue }
            cache = snapshot
            collection = snapshot.collection
            sets = known
            loaded = true
            #if DEBUG
            SpeedProbe.refreshed(in: ContinuousClock.now - started)
            SpeedProbe.built()
            #endif
            watchSets()
            return
        }
    }

    isolated deinit {
        if let saves { NotificationCenter.default.removeObserver(saves) }
    }

    /// Reads the album and the sets again, building only if something the collection reads differs. An album that can't be
    /// read keeps the last collection.
    private func refresh() {
        revision += 1
        guard loaded else { return }
        #if DEBUG
        let started = ContinuousClock.now
        defer { SpeedProbe.refreshed(in: ContinuousClock.now - started) }
        #endif
        guard let entries = Self.entries(in: container) else {
            log.error("couldn't read the album for the collection")
            return
        }
        guard cache.update(entries, sets: sets) else { return }
        collection = cache.collection
        #if DEBUG
        SpeedProbe.built()
        #endif
    }

    private func watchSets() {
        sets = withObservationTracking { readSets() } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let previous = self.sets
                self.watchSets()
                if previous != self.sets { self.refresh() }
            }
        }
    }

    private static func entries(in container: ModelContainer) -> [CardCollection.Entry]? {
        try? container.mainContext.fetch(FetchDescriptor<Sighting>()).map(CardCollection.Entry.init)
    }
}
