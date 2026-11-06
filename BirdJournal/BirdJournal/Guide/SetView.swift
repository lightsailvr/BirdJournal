import Album
import Pack
import SwiftUI
import UIKit

/// One set's page (issue #54, the reference's `4-set-page.png`): its plate, then one count of what's still out there, then its
/// species in collector order, each with its number; a species with a patch in the set shows the patch, and one not yet
/// found there shows its true silhouette, so browsing the set is a small game of shapes (issue #150, A3). Reached from the Atlas's
/// plates and the Collection's set progress; every row opens the bird's profile. Works for a set whose pack isn't downloaded: the
/// names come from the set definition, and a bird keeps the glyph until its pack is on the phone.
struct SetView: View {
    @Environment(PackLibrary.self) private var library
    @Environment(CollectionStore.self) private var collectionStore
    let id: String
    @State private var query = ""
    /// The plate names the set, so the bar only does once the plate has scrolled away.
    @State private var isPlateGone = false

    /// With no index entry there's no Download to offer yet, so this doesn't promise one.
    static func notOnPhoneText(canDownload: Bool) -> String {
        canDownload
            ? "This set's field guide isn't on your iPhone yet: downloading it adds photos, sounds and field notes, not birds. Patches you sew here count toward the set either way."
            : "This set's field guide isn't on your iPhone yet. It can download once the list of sets comes through, adding photos, sounds and field notes, not birds. Patches you sew here count toward the set either way."
    }

    var body: some View {
        if let set = library.sets.first(where: { $0.id == id }) {
            let collection = collectionStore.collection
            let progress = collection.progress(of: set.id)
            let pack = library.pack(id: set.id)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if query.isEmpty {
                        SetTile(set: set, progress: progress, opensSet: false)
                            .padding(.top, 4)
                    }
                    if query.isEmpty, pack == nil {
                        Text(Self.notOnPhoneText(canDownload: library.index?.descriptor(id: set.id) != nil))
                            .font(JournalFont.supporting)
                            .foregroundStyle(Color.inkSecondary)
                            .padding(.top, 8)
                    }
                    let shown = Array(set.species.enumerated()).filter { NameSearch.matches(query: query, in: [$0.element.commonName, $0.element.scientificName]) }
                    if shown.isEmpty {
                        NoSearchMatch(query: query) { query = "" }
                            .padding(.top, 12)
                    }
                    if query.isEmpty {
                        SectionTitle(progress.stillOutThereText, top: 20)
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(shown, id: \.element.scientificName) { offset, species in
                            let patch = collection.patch(scientificName: species.scientificName, setID: set.id)
                            NavigationLink(value: Route.species(scientificName: species.scientificName, commonName: species.commonName)) {
                                SetSpeciesRow(
                                    number: CardPlacement.paddedNumber(offset + 1, of: set.species.count), species: species,
                                    patch: patch, picture: .ofSetRow(scientificName: species.scientificName, setID: set.id, patch: patch, pack: pack)
                                )
                            }
                            .buttonStyle(.plain)
                            RowRule()
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, JournalLayout.margin)
                .padding(.bottom, JournalLayout.sectionGap)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > 200
            } action: { _, isGone in
                isPlateGone = isGone
            }
            .background(Color.paper)
            .holdsPatchLight()
            .navigationTitle(set.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    // The title itself, for the back button of whatever's pushed from here and VoiceOver.
                    Text(set.name)
                        .font(.headline)
                        .opacity(isPlateGone ? 1 : 0)
                        .accessibilityHidden(!isPlateGone)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search \(set.name) birds")
            // A set's page is in its own edition, wherever the birder is (issue #150).
            .tint(PatchEdition.tint(setID: set.id))
        } else {
            StateNotice("Set not found", message: "The list of sets no longer includes this one.", mark: .symbol("square.stack.3d.down.right"))
                .statePage()
        }
    }
}

/// One species of a set, as the reference draws it: your patch or its silhouette, the number above the name, and "Yours, seen once"
/// once it's sewn. A silhouette needs no words: the heading above counts them. The space after the name is free for a friend's
/// face (slice 8).
private struct SetSpeciesRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    /// e.g. "021".
    let number: String
    let species: PackSet.Species
    /// Yours, in this set.
    let patch: CardCollection.Patch?
    let picture: RowPictureSource

    /// The reference's tile, 138 of 900, at this screen's width.
    private static let pictureSide: CGFloat = 63

    /// "Yours, seen once"; "Yours, seen 3 times".
    private var yours: String? {
        patch.map { "Yours, seen \(CardCollection.Patch.times($0.count))" }
    }

    var body: some View {
        AdaptiveRow(stacked: typeSize.stacksRows) {
            RowPicture(source: picture, side: Self.pictureSide)
            VStack(alignment: .leading, spacing: 2) {
                Text("No. \(number)")
                    .font(JournalFont.attribution.monospacedDigit())
                    .foregroundStyle(Color.inkSecondary)
                Text(species.commonName)
                    .font(JournalFont.rowTitle)
                    .foregroundStyle(Color.ink)
                if let yours {
                    Text(yours)
                        .font(JournalFont.supporting)
                        .foregroundStyle(Color.inkSecondary)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([number, species.commonName, yours?.lowercased() ?? "still out there"].joined(separator: ", "))
        .accessibilityIdentifier(patch != nil ? "set-species-collected" : "set-species-silhouette")
    }
}

/// A bird not yet found: its true shape on the raised tile, or the glyph where there's none to show (a pack that isn't on the
/// phone, one without silhouettes, or a bird left out on purpose). It says "no patch yet", so it holds 3:1 on the raised surface.
/// The pack's picture is white and alpha, so it takes its colour here. It's a plain bitmap, and it takes no touches.
struct SpeciesSilhouette: View {
    /// How strong the glyph is over the raised surface (`TokenPairingTests`). A true shape is the secondary ink itself, as the reference
    /// draws it, which is stronger still.
    static let markOpacity = 0.75

    /// The pack's picture; nil is the glyph.
    let url: URL?
    @State private var image: UIImage?
    @State private var failed = false

    init(url: URL? = nil) {
        self.url = url
        _image = State(initialValue: url.flatMap(SilhouetteImages.cached))
    }

    var body: some View {
        ZStack {
            Color.raised
            if let image {
                Image(uiImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .padding(7)
                    .foregroundStyle(Color.inkSecondary)
            } else if url == nil || failed {
                Image(systemName: "bird.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(14)
                    .foregroundStyle(Color.inkSecondary.opacity(Self.markOpacity))
            }
        }
        .allowsHitTesting(false)
        .task(id: url) {
            guard let url, image == nil else { return }
            image = await SilhouetteImages.load(url)
            failed = image == nil
        }
    }
}

/// Silhouettes, decoded once and off the main actor: a set's rows come and go as it scrolls, and a row scrolled back to shouldn't
/// flash an empty tile.
enum SilhouetteImages {
    private nonisolated(unsafe) static let cache = NSCache<NSURL, UIImage>()

    static func cached(_ url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    static func load(_ url: URL) async -> UIImage? {
        if let hit = cached(url) { return hit }
        return await Task.detached(priority: .userInitiated) {
            let image = UIImage(contentsOfFile: url.path(percentEncoded: false))?.preparingForDisplay()
            if let image { cache.setObject(image, forKey: url as NSURL) }
            return image
        }.value
    }
}
