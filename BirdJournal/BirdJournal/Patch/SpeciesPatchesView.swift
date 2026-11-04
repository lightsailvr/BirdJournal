import Album
import Pack
import SwiftData
import SwiftUI

/// One bird's patches across places (issue #134, guide page 7): each edition's patch with its count, on felt, and the
/// editions still to find as patterns. Reached from the Species list and the Atlas profile.
struct SpeciesPatchesView: View {
    @Environment(PackLibrary.self) private var library
    @Environment(PlaceNames.self) private var places
    @Environment(\.dynamicTypeSize) private var typeSize
    @Query(Sighting.newestFirst()) private var sightings: [Sighting]
    let scientificName: String
    let commonName: String

    var body: some View {
        let collection = library.collection(of: sightings)
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
                    FeltBoard {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 18) {
                            ForEach(patches) { patch in
                                SewnPatchTile(patch: patch, name: patch.placement.editionLabel, line: "\(patch.placement.setName) · seen \(patch.count)×", spokenName: name)
                            }
                        }
                    }
                    .padding(.top, 14)
                }
                let toFind = collection.setsToFind(scientificName: scientificName)
                if !toFind.isEmpty {
                    StillToFind(scientificName: scientificName, sets: toFind)
                        .padding(.horizontal, JournalLayout.margin)
                        .padding(.top, JournalLayout.sectionGap - 8)
                }
                VStack(alignment: .leading, spacing: 10) {
                    if let latest = ofSpecies.first {
                        Text("Most recent: \(SpeciesRowsText.lastSeen(latest.confirmedAt))\(latest.location.flatMap(places.name(for:)).map { ", \($0)" } ?? "")")
                            .font(JournalFont.attribution)
                            .foregroundStyle(Color.inkSecondary)
                            .accessibilityIdentifier("species-latest")
                        NavigationLink(value: Route.sightings(.species(speciesID: latest.speciesID))) {
                            Label("All \(PatchText.sightings(ofSpecies.count))", systemImage: "list.bullet")
                        }
                        .buttonStyle(.journalOutlined)
                        .accessibilityIdentifier("species-all-sightings")
                    }
                    NavigationLink(value: Route.species(scientificName: scientificName, commonName: name)) {
                        Label("Open in Field Guide", systemImage: "book")
                    }
                    .buttonStyle(.journalOutlined)
                }
                .padding(.horizontal, JournalLayout.margin)
                .padding(.top, JournalLayout.sectionGap - 8)
            }
            .padding(.bottom, JournalLayout.sectionGap)
        }
        .background(Color.paper)
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
                .foregroundStyle(Color.inkSecondary)
            if let first = patches.map(\.sewn.confirmedAt).min() {
                Text("\(CardCollection.Patch.speciesSummary(patches)) · since \(first.formatted(.dateTime.month(.abbreviated).day()))")
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.inkSecondary)
                    .padding(.top, 4)
                    .accessibilityIdentifier("species-summary")
            }
        }
        .padding(.top, 4)
    }
}

/// The editions still to find: each set's pattern of the bird, or its blank where the set's pack isn't on the phone.
private struct StillToFind: View {
    @Environment(PackLibrary.self) private var library
    @Environment(\.dynamicTypeSize) private var typeSize
    let scientificName: String
    let sets: [CardSet]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Still to find in")
                .textCase(.uppercase)
                .font(CardFont.editionCompact)
                .tracking(CardFont.editionCompactTracking)
                .foregroundStyle(Color.inkSecondary)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: PatchBoardLayout.grid(for: typeSize), spacing: 14) {
                ForEach(sets) { set in
                    VStack(spacing: 4) {
                        PatchView(art: library.patchArt(scientificName: scientificName, setID: set.id), edition: PatchEdition.of(setID: set.id), face: .pattern)
                            .frame(maxWidth: 88)
                        Text(set.name)
                            .font(.caption)
                            .foregroundStyle(Color.ink)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(set.name), \(set.edition), not yet found")
                    .accessibilityIdentifier("species-to-find")
                }
            }
        }
    }
}

/// A species with no sightings: its guide photo and names, and the way to Listen.
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
            Text("No sightings of \(commonName) yet")
                .font(JournalFont.section)
                .foregroundStyle(Color.ink)
                .padding(.top, 14)
                .accessibilityAddTraits(.isHeader)
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
    /// This patch's sightings among `sightings`, in their order.
    func ownSightings(among sightings: [Sighting]) -> [Sighting] {
        let own = Set(self.sightings.map(\.identifier))
        return sightings.filter { own.contains($0.identifier) }
    }
}

/// The sightings behind a patch, or behind every patch of a species: newest first, each opening its sighting.
struct PatchSightingsView: View {
    @Environment(PackLibrary.self) private var library
    @Query(Sighting.newestFirst()) private var sightings: [Sighting]
    let scope: SightingsScope

    var body: some View {
        let shown = shownSightings
        PaperPage {
            VStack(spacing: 0) {
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
        case .species(let speciesID): sightings.filter { $0.speciesID == speciesID }
        case .patch(let key): library.collection(of: sightings).patch(key: key)?.ownSightings(among: sightings) ?? []
        }
    }
}
