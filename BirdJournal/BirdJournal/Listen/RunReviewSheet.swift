import Album
import Identification
import Pack
import SwiftUI

/// The end of a run (issues #28, #150): a recap printed on paper, with a picture of it to share, then every species heard, so
/// a bird skipped can still be added, and what becomes of the rest. In memory only; a named outing is deferred.
struct RunReviewSheet: View {
    @Environment(ListeningCoordinator.self) private var run
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openCollection) private var openCollection
    @Environment(\.scenePhase) private var scenePhase
    @Environment(CollectionStore.self) private var collectionStore
    @Environment(PackLibrary.self) private var library
    @Environment(PlaceNames.self) private var places
    @State private var reviewing: Candidate?
    @State private var pictures: [RunRecap.Picture] = []
    /// The patches `pictures` was drawn for: until it catches up, there's no image to share, not one missing a patch.
    @State private var drawnFor: [CardCollection.Patch.Key]?
    @State private var includeCity = true
    @State private var export: CardExport?

    private var collection: CardCollection { collectionStore.collection }

    /// The patches this run sewed, in the order they were sewn: the add that sewed one may have been undone, and a later add
    /// then holds it.
    private var sewn: [CardCollection.Patch] {
        var seen = Set<CardCollection.Patch.Key>()
        return run.sightings.entries.compactMap { entry in
            guard collection.sewedItsPatch(entry.identifier), let patch = collection.patch(of: entry.identifier), seen.insert(patch.id).inserted else { return nil }
            return patch
        }
    }

    private func name(of patch: CardCollection.Patch) -> String {
        patch.commonName(in: library)
    }

    private var place: String? {
        SharePolicy.recapPlace(
            placeName: run.coordinate.flatMap(places.name(for:)), hasLocation: run.coordinate != nil,
            pictured: sewn.map { library.species(scientificName: $0.scientificName)?.species.isThreatened }, includeCity: includeCity
        )
    }

    private var recap: RunRecap {
        RunRecap(startedAt: run.startedAt, endedAt: run.endedAt ?? .now, place: place, birdsHeard: run.candidates.count, patchNames: sewn.map(name(of:)))
    }

    /// Who took the photos the pictured patches were stitched from, for the image and its text.
    private var credits: [String] {
        sewn.flatMap { patch -> [String] in
            guard let found = library.patch(scientificName: patch.scientificName, setID: patch.placement.setID),
                  let species = found.pack.species(scientificName: patch.scientificName) else { return [] }
            return PatchShareImage.Facts.credits(of: found.patch, in: species)
        }
    }

    private var hasPainting: Bool {
        sewn.contains { library.patchArt(scientificName: $0.scientificName, setID: $0.placement.setID) != nil }
    }

    /// Only while the app is in front: drawing these needs the GPU, and Stop on the Lock Screen brings this up behind it.
    private struct PicturesKey: Equatable {
        var patches: [CardCollection.Patch.Key]
        var isActive: Bool
    }

    private struct ExportKey: Equatable {
        var recap: RunRecap
        var isReady: Bool
    }

    var body: some View {
        NavigationStack {
            PaperPage {
                VStack(alignment: .leading, spacing: 0) {
                    RunRecapCard(recap: recap, pictures: pictures)
                        .padding(.top, 8)
                    if run.coordinate != nil {
                        Toggle(isOn: $includeCity) { Label("City", systemImage: "building.2") }
                            .tint(Color.moss)
                            .font(JournalFont.body)
                            .foregroundStyle(Color.ink)
                            .padding(.top, 14)
                            .accessibilityIdentifier("recap-city")
                    }
                    Label(recap.placeExplanation(hasLocation: run.coordinate != nil, includeCity: includeCity), systemImage: "checkmark.shield")
                        .font(JournalFont.supporting)
                        .foregroundStyle(Color.inkSecondary)
                        .padding(.top, 6)
                        .accessibilityIdentifier("recap-place-explanation")

                    SectionTitle("What you heard")
                    VStack(spacing: 0) {
                        ForEach(run.orderedCandidates) { candidate in
                            CandidateRow(candidate: candidate, isAdded: run.isAdded(candidate), startedAt: run.startedAt, seenHere: collection.count(ofSpeciesID: candidate.species.birdnetLabel, at: run.coordinate)) {
                                reviewing = candidate
                            }
                            RowRule()
                        }
                    }
                    .padding(.top, 8)
                    Text("Only the birds you add are kept. The rest are forgotten when you close this.")
                        .font(JournalFont.supporting)
                        .foregroundStyle(Color.inkSecondary)
                        .padding(.top, 12)
                }
            }
            .navigationTitle("Your run")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(item: $reviewing) { candidate in
                CandidateReviewView(candidate: candidate)
            }
            .appDestinations()
            .scrollEdgeEffectStyle(.hard, for: .bottom)
            .safeAreaBar(edge: .bottom) {
                VStack(spacing: 8) {
                    if let acknowledgment = run.acknowledgment {
                        Toast(text: acknowledgment.text, undo: acknowledgment.undo.map { addition in { run.undo(addition) } }, ticksFrom: acknowledgment.ticksFrom)
                            .id(acknowledgment.id)
                    }
                    Group {
                        if let export {
                            ShareLink(item: export, message: Text(export.text), preview: SharePreview(export.title, image: Image(uiImage: export.image))) {
                                Label("Share image", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                            .accessibilityIdentifier("recap-share")
                        } else {
                            Label("Preparing the image…", systemImage: "square.and.arrow.up")
                                .foregroundStyle(Color.inkSecondary)
                        }
                    }
                    .buttonStyle(.journalOutlined)
                    .padding(.horizontal, JournalLayout.margin)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .task(id: PicturesKey(patches: sewn.map(\.id), isActive: scenePhase == .active)) {
                guard scenePhase == .active else { return }
                await drawPictures()
            }
            .task(id: ExportKey(recap: recap, isReady: scenePhase == .active && drawnFor == sewn.map(\.id))) {
                export = nil
                guard scenePhase == .active, drawnFor == sewn.map(\.id) else { return }
                render()
            }
            .task(id: run.coordinate) {
                if let coordinate = run.coordinate { await places.resolve(coordinate) }
            }
        }
        .patchReveal()
        // Dragged away from under the page, it would have to start again over the tabs; Keep listening closes it first.
        .interactiveDismissDisabled(run.reveal != nil)
        // See it in my collection from a reveal over this sheet: the review closes, as Done does, so the collection shows.
        .environment(\.openCollection) {
            dismiss()
            openCollection()
        }
        .onDisappear { run.dismissEnded() }
    }

    /// Flat pictures of the sewn patches: a page full of shaders isn't what a printed recap is, and they go into the image.
    private func drawPictures() async {
        let patches = sewn
        var drawn: [RunRecap.Picture] = []
        for patch in patches {
            if let known = pictures.first(where: { $0.id == patch.id }) {
                drawn.append(known)
                continue
            }
            var loaded: PatchTextures.Loaded?
            if let art = library.patchArt(scientificName: patch.scientificName, setID: patch.placement.setID) {
                loaded = await PatchTextures.load(art, size: .thumbnail)
            }
            guard !Task.isCancelled else { return }
            if let image = FlatPatch.render(loaded: loaded, edition: PatchEdition.of(setID: patch.placement.setID), tag: name(of: patch), width: 80, scale: CardExport.imageScale) {
                drawn.append(RunRecap.Picture(id: patch.id, image: image))
            }
        }
        pictures = drawn
        drawnFor = patches.map(\.id)
    }

    /// The image as the system share takes it: a fresh PNG with nothing but its pixels.
    private func render() {
        let credits = credits
        let image = RunRecapShareImage(recap: recap, pictures: pictures, imprint: RunRecap.imprint(hasPainting: hasPainting), credits: RunRecap.creditLine(credits))
        guard let rendered = CardExport.render(image, scale: CardExport.imageScale) else { return }
        export = CardExport(image: rendered.image, png: rendered.png, text: recap.shareText(credits: credits), title: "Your run · Featherguild")
        #if DEBUG
        // `-saveRecapImage YES`: what the system share would send, in the app's tmp, for the screenshots.
        if UserDefaults.standard.bool(forKey: "saveRecapImage") {
            try? rendered.png.write(to: URL.temporaryDirectory.appending(path: "recap-share.png"))
        }
        #endif
    }
}
