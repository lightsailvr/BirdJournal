import Album
import Pack
import SwiftData
import SwiftUI

/// One bird's patches across places (issue #134, guide page 7): each edition's patch with its count, on felt. A place you
/// haven't found it has no patch. Reached from the Species list and the Atlas profile.
struct SpeciesPatchesView: View {
    @Environment(PackLibrary.self) private var library
    @Environment(PlaceNames.self) private var places
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
            VStack(alignment: .leading, spacing: 0) {
                header(name: name, patches: patches)
                    .padding(.horizontal, JournalLayout.margin)
                if patches.isEmpty {
                    NoPatchesYet(scientificName: scientificName, commonName: name)
                        .padding(.horizontal, JournalLayout.margin)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 18) {
                        ForEach(patches) { patch in
                            SewnPatchTile(patch: patch, name: patch.placement.editionLabel, line: patch.count == 1 ? patch.placement.setName : "\(patch.placement.setName) · seen \(patch.count)×", spokenName: name, surface: .species)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 18)
                }
                VStack(alignment: .leading, spacing: 10) {
                    if let latest = ofSpecies.first {
                        Text("Most recent: \(SpeciesRowsText.lastSeen(latest.confirmedAt))\(latest.location.flatMap(places.name(for:)).map { ", \($0)" } ?? "")")
                            .font(JournalFont.attribution)
                            .foregroundStyle(Color.ink)
                            .boardLabel()
                            .accessibilityIdentifier("species-latest")
                        NavigationLink(value: Route.sightings(.species(speciesID: latest.speciesID))) {
                            Label(ofSpecies.count == 1 ? PatchText.sightings(1) : "All \(PatchText.sightings(ofSpecies.count))", systemImage: "list.bullet")
                        }
                        .buttonStyle(.journalOutlined)
                        .accessibilityIdentifier("species-all-sightings")
                    }
                    NavigationLink(value: Route.species(scientificName: scientificName, commonName: name)) {
                        Label("Open in Atlas", systemImage: "book")
                    }
                    .buttonStyle(.journalOutlined)
                }
                .padding(.horizontal, JournalLayout.margin)
                .padding(.top, JournalLayout.sectionGap - 8)
            }
            .padding(.bottom, JournalLayout.sectionGap)
        }
        .background {
            if patches.isEmpty { Color.paper.ignoresSafeArea() } else { BoardMaterial().ignoresSafeArea() }
        }
        .holdsPatchLight()
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: ofSpecies.first?.location) {
            if let location = ofSpecies.first?.location { await places.resolve(location) }
        }
    }

    private func header(name: String, patches: [CardCollection.Patch]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
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
        VStack(alignment: .leading, spacing: 0) {
            if let reference, let photo = reference.species.photos.first {
                AttributedImage(pack: reference.pack, photo: photo)
                    .padding(.top, 12)
            }
            SectionTitle("No sightings of \(commonName) yet", size: .lead, top: 14)
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
            .buttonStyle(.journalPrimary)
            .padding(.top, 16)
        }
    }
}

/// Whose sightings a list shows.
enum SightingsScope: Hashable {
    case patch(CardCollection.Patch.Key)
    case species(speciesID: String)
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

/// The sightings behind a patch, or behind every patch of a species: newest first, each opening its sighting.
struct PatchSightingsView: View {
    @Environment(CollectionStore.self) private var collectionStore
    @Query(Sighting.newestFirst()) private var sightings: [Sighting]
    let scope: SightingsScope

    var body: some View {
        let shown = shownSightings
        PaperPage {
            // Lazy: a bird seen hundreds of times asks for only the rows on screen, each a live patch unless it has a photo.
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
        .holdsPatchLight()
        .navigationTitle(PatchText.sightings(shown.count))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var shownSightings: [Sighting] {
        switch scope {
        case .species(let speciesID): sightings.filter { $0.speciesID == speciesID }
        case .patch(let key): collectionStore.collection.patch(key: key)?.ownSightings(among: sightings) ?? []
        }
    }
}
