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
            return SetCount(setID: id, setName: progress.name, sewn: progress.collected, total: progress.total)
        }
    }
}

/// Keeps the widget's two files in step with the collection: the words and the flat picture of the patch, in the App Group, as
/// the rule in `WidgetSnapshot.rewrite` says. Lighting a patch needs the GPU, which an app behind a locked phone can't have, so a
/// patch the lens sews there goes up as its plain painting, and is lit when the app is next in front.
@MainActor
final class LatestPatchPublisher {
    private let store: WidgetStore
    private let collection: CollectionStore
    private let packs: PackLibrary
    private let draw: @MainActor (WidgetSnapshot.Latest) async -> DrawnPatch?
    private let log = Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "album")
    private var publishing: Task<Void, Never>?
    private var activation: (any NSObjectProtocol)?

    /// The patch as a picture, and whether it's the painting, lit. A blank, or a plain painting behind a locked phone, gets
    /// another go once there's a painting to light.
    struct DrawnPatch {
        let png: Data
        let isLit: Bool
    }

    /// The patch's points on the picture and pixels per point, with the shadow's `FlatPatch.room` around it. A small widget on
    /// a 2x phone can hold 375,161 px of image in all, with the felt (`picturesFitAWidget`).
    static let patchWidth: CGFloat = 160
    static let patchScale: CGFloat = 2.4

    /// - Parameters:
    ///   - draw: draws the picture; nil when it couldn't. By default `FlatPatch`.
    ///   - isInFront: whether the GPU is there to light a patch with.
    init(store: WidgetStore, collection: CollectionStore, packs: PackLibrary, draw: (@MainActor (WidgetSnapshot.Latest) async -> DrawnPatch?)? = nil, isInFront: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .active }) {
        self.store = store
        self.collection = collection
        self.packs = packs
        self.draw = draw ?? { await Self.drawPatch($0, packs: packs, isInFront: isInFront) }
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
            name: { PatchText.name(of: $0, library: packs) },
            hasPainting: { packs.patchArt(scientificName: $0.scientificName, setID: $0.placement.setID) != nil }
        )
    }

    private func publish() {
        publishing?.cancel()
        publishing = Task { await write() }
    }

    /// Brings the files up to date, if the rule says they need it. With no picture of a new patch nothing is written, since the
    /// words would then name a bird the old picture isn't of, and the rule tries again next time. A painting that wouldn't
    /// decode is written as the blank it drew, marked as no painting, so the rule tries that again too, as for a plain one.
    func write() async {
        var new = snapshot()
        let rewrite = WidgetSnapshot.rewrite(from: store.snapshot(), to: new, hasPatchImage: store.hasPatchImage)
        guard rewrite != .nothing else { return }
        var png: Data?
        if rewrite == .wordsAndPatch, let latest = new.latest {
            let drawn = await draw(latest)
            guard !Task.isCancelled else { return }
            guard let drawn else {
                log.error("couldn't draw the widget's patch")
                return
            }
            png = drawn.png
            new.latest?.hasPainting = drawn.isLit
        }
        do {
            try store.write(new, patchPNG: png)
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshot.widgetKind)
        } catch {
            log.error("couldn't write the widget's files: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func drawPatch(_ latest: WidgetSnapshot.Latest, packs: PackLibrary, isInFront: @MainActor () -> Bool) async -> DrawnPatch? {
        let name = Sighting.scientificName(ofLabel: latest.link.speciesID)
        let edition = PatchEdition.of(setID: latest.link.setID)
        var loaded: PatchTextures.Loaded?
        if let art = packs.patchArt(scientificName: name, setID: latest.link.setID) { loaded = await PatchTextures.load(art, size: .full) }
        // Asked after the decode, which can outlast the app's moment in front.
        if isInFront() {
            let image = FlatPatch.render(loaded: loaded, edition: edition, tag: latest.name, width: patchWidth, scale: patchScale)
            return image?.pngData().map { DrawnPatch(png: $0, isLit: loaded != nil) }
        }
        guard let loaded else { return nil }
        let image = FlatPatch.unlit(loaded: loaded, edition: edition, width: patchWidth, scale: patchScale)
        return image.pngData().map { DrawnPatch(png: $0, isLit: false) }
    }
}
