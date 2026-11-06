import Album
import Foundation
import Observation
import OSLog
import Pack
import UIKit
import WidgetKit

extension WidgetSnapshot {
    /// The widget's value from the collection (issue #150): the most recently sewn patch, and the progress of its set, or of
    /// the local set (`LocalSet`'s rule) when there's no patch yet or the newest is Uncharted.
    init(collection: CardCollection, localSetID: String?, name: (CardCollection.Patch) -> String, hasPainting: (CardCollection.Patch) -> Bool) {
        latest = collection.patches.first.map { patch in
            Latest(link: PatchLink(speciesID: patch.speciesID, setID: patch.placement.setID), name: name(patch), setName: patch.placement.setName, hasPainting: hasPainting(patch))
        }
        progress = (collection.patches.first?.placement.setID ?? localSetID).map { id in
            let progress = collection.progress(of: id)
            return Progress(setID: id, setName: progress.name, sewn: progress.collected, total: progress.total)
        }
    }
}

/// Keeps the widget's two files in step with the collection: the words and the flat picture of the patch, in the App Group, as
/// the rule in `WidgetSnapshot.rewrite` says. The picture needs the GPU, which an app behind a locked phone can't have, so a
/// patch the lens sews there reaches the widget when the app is next in front.
@MainActor
final class LatestPatchPublisher {
    private let store: WidgetStore
    private let collection: CollectionStore
    private let packs: PackLibrary
    private let log = Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "album")
    private var publishing: Task<Void, Never>?
    private var activation: (any NSObjectProtocol)?

    init(store: WidgetStore, collection: CollectionStore, packs: PackLibrary) {
        self.store = store
        self.collection = collection
        self.packs = packs
    }

    /// From now on, whenever the collection changes and whenever the app comes to the front.
    func follow() {
        activation = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.publish() }
        }
        observe()
    }

    private func observe() {
        _ = withObservationTracking { collection.collection } onChange: { [weak self] in
            Task { @MainActor in
                self?.publish()
                self?.observe()
            }
        }
    }

    private func snapshot() -> WidgetSnapshot {
        let collection = collection.collection
        let packs = packs
        let local = LocalSet.find(library: packs, collection: collection, newest: collection.cards.first)
        return WidgetSnapshot(
            collection: collection,
            localSetID: local?.set.id,
            name: { patch in packs.species(scientificName: patch.scientificName)?.species.commonName ?? String(patch.speciesID.drop { $0 != "_" }.dropFirst()) },
            hasPainting: { packs.patchArt(scientificName: $0.scientificName, setID: $0.placement.setID) != nil }
        )
    }

    private func publish() {
        guard UIApplication.shared.applicationState == .active else { return }
        publishing?.cancel()
        publishing = Task { await write() }
    }

    /// Brings the files up to date, if the rule says they need it.
    func write() async {
        let new = snapshot()
        let rewrite = WidgetSnapshot.rewrite(from: store.snapshot(), to: new, hasPatchImage: store.hasPatchImage)
        guard rewrite != .nothing else { return }
        var png: Data?
        if rewrite == .wordsAndPatch, let latest = new.latest {
            png = await patchPNG(of: latest)
            guard !Task.isCancelled else { return }
        }
        do {
            try store.write(new, patchPNG: png)
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshot.widgetKind)
        } catch {
            log.error("couldn't write the widget's files: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func patchPNG(of latest: WidgetSnapshot.Latest) async -> Data? {
        let name = Sighting.scientificName(ofLabel: latest.link.speciesID)
        let edition = PatchEdition.of(setID: latest.link.setID)
        var loaded: PatchTextures.Loaded?
        if let art = packs.patchArt(scientificName: name, setID: latest.link.setID) {
            loaded = await PatchTextures.load(art, size: .full)
        }
        return FlatPatch.render(loaded: loaded, edition: edition, tag: latest.name, width: 160, scale: 3)?.pngData()
    }
}
