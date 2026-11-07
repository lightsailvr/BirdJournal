import Album
import Pack
import SwiftData
import SwiftUI

/// One bird's patches across places (issue #134, guide page 7): each edition's patch with its count, on felt. A place you
/// haven't found it has no patch. Reached from the Species list and the Atlas profile.
struct SpeciesPatchesView: View {
    @Environment(PackLibrary.self) private var library
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(CollectionStore.self) private var collectionStore
    @Query(Sighting.newestFirst()) private var sightings: [Sighting]
    let scientificName: String
    let commonName: String

    var body: some View {
        let collection = collectionStore.collection
        let ofSpecies = sightings.filter { $0.scientificName == scientificName }
        let patches = collection.patches.filter { $0.scientificName == scientificName }.sorted { $0.sewn.confirmedAt < $1.sewn.confirmedAt }
        let name = library.species(scientificName: scientificName)?.species.commonName ?? ofSpecies.first?.commonName ?? commonName
        ScrollView {
            VStack(spacing: 0) {
                header(name: name, patches: patches)
                    .padding(.horizontal, JournalLayout.margin)
                if patches.isEmpty {
                    NoPatchesYet(scientificName: scientificName, commonName: name)
                        .padding(.horizontal, JournalLayout.margin)
                } else {
                    patchHeroes(patches, name: name)
                        .padding(.top, 18)
                }
                NavigationLink(value: Route.species(scientificName: scientificName, commonName: name)) {
                    Label("Open in Atlas", systemImage: "book")
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.journalPrimary)
                .accessibilityIdentifier("species-open-atlas")
                .padding(.horizontal, JournalLayout.margin)
                .padding(.top, 24)

                if !ofSpecies.isEmpty {
                    sightingList(ofSpecies)
                        .padding(.top, 28)
                }
            }
            .padding(.bottom, JournalLayout.sectionGap)
        }
        .background {
            if patches.isEmpty { Color.paper.ignoresSafeArea() } else { BoardMaterial().ignoresSafeArea() }
        }
        .holdsPatchLight()
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// A single patch has the patch page's footprint. Several keep that scale in a centred, snapping carousel;
    /// accessibility text uses a reading column so no horizontal gesture is needed to reach an edition's words.
    @ViewBuilder
    private func patchHeroes(_ patches: [CardCollection.Patch], name: String) -> some View {
        if patches.count == 1 || typeSize.isAccessibilitySize {
            VStack(spacing: 28) {
                ForEach(patches) { patch in
                    hero(patch, name: name)
                }
            }
            .padding(.horizontal, JournalLayout.margin)
        } else {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(patches) { patch in
                        hero(patch, name: name)
                            .containerRelativeFrame(.horizontal)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, JournalLayout.margin, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .accessibilityIdentifier("species-patch-carousel")
        }
    }

    private func hero(_ patch: CardCollection.Patch, name: String) -> some View {
        SewnPatchTile(
            patch: patch, name: patch.placement.setName, line: PatchText.pageLine(patch),
            spokenName: name, surface: .species, side: 286, pictureSize: .full,
            nameFont: JournalFont.heading, lineFont: JournalFont.supporting
        )
        .frame(maxWidth: .infinity)
    }

    private func sightingList(_ sightings: [Sighting]) -> some View {
        // Keep the sightings on matte paper, like the Journal's list; only the patches live on felt.
        LazyVStack(alignment: .leading, spacing: 0) {
            SectionTitle(PatchText.sightings(sightings.count), top: 18)
                .padding(.bottom, 8)
            ForEach(sightings) { sighting in
                NavigationLink(value: Route.sighting(sighting.persistentModelID)) {
                    SightingRow(sighting: sighting, showsDate: true)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("species-sighting")
                RowRule()
            }
        }
        .padding(.horizontal, JournalLayout.margin)
        .padding(.bottom, 12)
        .background(Color.paper)
    }

    private func header(name: String, patches: [CardCollection.Patch]) -> some View {
        VStack(spacing: 2) {
            Text(name)
                .font(JournalFont.title)
                .foregroundStyle(Color.ink)
                .accessibilityAddTraits(.isHeader)
            Text(scientificName)
                .font(JournalFont.scientific)
                .foregroundStyle(Color.ink)
            if let first = patches.map(\.sewn.confirmedAt).min() {
                Text("\(CardCollection.Patch.speciesSummary(patches)), since \(first.formatted(.dateTime.month(.abbreviated).day()))")
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.ink)
                    .padding(.top, 4)
                    .accessibilityIdentifier("species-summary")
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .boardLabel(horizontal: 12, vertical: 8, isOnBoard: !patches.isEmpty)
        .padding(.top, 4)
    }
}

/// A species with no sightings, not yet found (guide page 15, without the pattern: see DECISIONS.md, issue #138): its guide
/// photo and names, its number in each set that lists it, and the way to Listen. The page's "Open in Field Guide" is the path
/// to its Atlas profile.
private struct NoPatchesYet: View {
    @Environment(PackLibrary.self) private var library
    @Environment(\.openListen) private var openListen
    let scientificName: String
    let commonName: String

    var body: some View {
        let reference = library.species(scientificName: scientificName)
        VStack(spacing: 0) {
            if let reference, let photo = reference.species.photos.first {
                AttributedImage(pack: reference.pack, photo: photo)
                    .padding(.top, 12)
            }
            Text("No sightings of \(commonName) yet")
                .font(JournalFont.heading)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 14)
            ForEach(PatchText.setNumbers(of: scientificName, in: library.sets), id: \.self) { number in
                Text(number.text)
                    .font(JournalFont.supporting.monospacedDigit())
                    .foregroundStyle(Color.inkSecondary)
                    .padding(.top, 2)
                    .accessibilityLabel(number.spoken)
                    .accessibilityIdentifier("species-set-number")
            }
            Text("Add this bird when you hear it on a run. Its first sighting in a place sews its patch there, and every sighting after adds to its count.")
                .font(JournalFont.body)
                .foregroundStyle(Color.inkSecondary)
                .padding(.top, 12)
            Button {
                openListen()
            } label: {
                Label("Start listening", systemImage: "waveform")
            }
            .buttonStyle(.journalOutlined)
            .padding(.top, 16)
        }
        .multilineTextAlignment(.center)
    }
}

/// Whose sightings a list shows.
enum SightingsScope: Hashable {
    case patch(CardCollection.Patch.Key)
}

extension CardCollection.Patch {
    /// The album by identifier, for finding many patches' sightings in it.
    static func table(of sightings: [Sighting]) -> [UUID: Sighting] {
        Dictionary(sightings.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// This patch's sightings from the album's `table`, newest first.
    func ownSightings(in table: [UUID: Sighting]) -> [Sighting] {
        sightings.compactMap { table[$0.identifier] }
    }

    /// This patch's sightings among `sightings`, newest first.
    func ownSightings(among sightings: [Sighting]) -> [Sighting] {
        ownSightings(in: Self.table(of: sightings))
    }
}

/// The sightings behind one patch: newest first, each opening its sighting. Species pages list theirs inline.
struct PatchSightingsView: View {
    @Environment(CollectionStore.self) private var collectionStore
    @Query(Sighting.newestFirst()) private var sightings: [Sighting]
    let scope: SightingsScope

    var body: some View {
        let shown = shownSightings
        PaperPage {
            // Lazy: a bird seen hundreds of times asks for only the rows on screen.
            LazyVStack(spacing: 0) {
                ForEach(shown) { sighting in
                    NavigationLink(value: Route.sighting(sighting.persistentModelID)) {
                        SightingRow(sighting: sighting, showsDate: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("patch-sighting")
                    RowRule()
                }
            }
        }
        .navigationTitle(PatchText.sightings(shown.count))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var shownSightings: [Sighting] {
        switch scope {
        case .patch(let key): collectionStore.collection.patch(key: key)?.ownSightings(among: sightings) ?? []
        }
    }
}
