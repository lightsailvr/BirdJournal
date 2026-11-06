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
    private let log = Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "album")

    /// - Parameter sets: every set the phone knows, read under observation, so a pack download or a new index reaches it.
    init(container: ModelContainer, sets: @escaping () -> [CardSet]) {
        self.container = container
        readSets = sets
        #if DEBUG
        let started = ContinuousClock.now
        defer { SpeedProbe.refreshed(in: ContinuousClock.now - started); SpeedProbe.built() }
        #endif
        let known = sets()
        self.sets = known
        let cache = CardCollectionCache(Self.entries(in: container) ?? [], sets: known)
        self.cache = cache
        collection = cache.collection
        watchSets()
        saves = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) { [weak self, container] note in
            guard (note.object as? ModelContext)?.container === container else { return }
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.refresh() }
            } else {
                Task { @MainActor in self?.refresh() }
            }
        }
    }

    isolated deinit {
        if let saves { NotificationCenter.default.removeObserver(saves) }
    }

    /// Reads the album and the sets again, building only if something the collection reads differs. An album that can't be
    /// read keeps the last collection.
    private func refresh() {
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
                self?.watchSets()
                self?.refresh()
            }
        }
    }

    private static func entries(in container: ModelContainer) -> [CardCollection.Entry]? {
        try? container.mainContext.fetch(FetchDescriptor<Sighting>()).map(CardCollection.Entry.init)
    }
}
