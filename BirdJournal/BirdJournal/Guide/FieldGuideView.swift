import Album
import Pack
import SwiftUI

/// The Atlas tab (issue #28's Field Guide, reskinned as the Atlas in #118, design guide pages 4 and 14): the regional
/// sets as printed plates (issue #150), the ones on this iPhone first and then "Somewhere new", each keeping "Species
/// collected" (the birder's progress) apart from "Ready offline" (the pack on the phone); the way to the bird packs; and
/// every bird the installed packs describe, searchable with the sets by name. A download adds field-guide material,
/// never birds: a bird joins the collection only with a sighting.
struct FieldGuideView: View {
    @Environment(PackLibrary.self) private var library
    @Environment(CollectionStore.self) private var collectionStore
    @State private var query = ""

    /// Every species across the packs, bundled first, each once.
    private var entries: [(pack: SpeciesPack, species: PackSpecies)] {
        var seen = Set<String>()
        var entries: [(SpeciesPack, PackSpecies)] = []
        for pack in library.packs {
            for species in pack.species where seen.insert(species.scientificName).inserted {
                entries.append((pack, species))
            }
        }
        return entries
    }

    private func shown(among entries: [(pack: SpeciesPack, species: PackSpecies)]) -> [(pack: SpeciesPack, species: PackSpecies)] {
        entries
            .filter { NameSearch.matches(query: query, in: [$0.species.commonName, $0.species.scientificName]) }
            .sorted { $0.species.commonName.localizedCaseInsensitiveCompare($1.species.commonName) == .orderedAscending }
    }

    private var shownSets: [PackSet] {
        library.sets.filter { set in
            NameSearch.matches(query: query, in: [set.name, set.edition.name, library.index?.descriptor(id: set.id)?.region ?? ""])
        }
    }

    var body: some View {
        let collection = collectionStore.collection
        let sets = shownSets
        let entries = entries
        let shown = shown(among: entries)
        let onPhone = sets.filter { library.pack(id: $0.id) != nil }
        let elsewhere = sets.filter { library.pack(id: $0.id) == nil }
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if library.indexError != nil, !library.isRefreshingIndex {
                    OfflineNotice(hasIndex: library.index != nil) { Task { await library.refreshIndex() } }
                        .padding(.top, 8)
                }
                LazyVStack(spacing: 16) {
                    ForEach(onPhone) { set in
                        SetTile(set: set, progress: collection.progress(of: set.id))
                    }
                }
                .padding(.top, 8)
                if !elsewhere.isEmpty {
                    SectionTitle("Somewhere new")
                        .id("atlas-new")
                    LazyVStack(spacing: 16) {
                        ForEach(elsewhere) { set in
                            SetTile(set: set, progress: collection.progress(of: set.id))
                        }
                    }
                    .padding(.top, 12)
                }
                if query.isEmpty {
                    NavigationLink(value: Route.packs) {
                        PacksCard(library: library)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, JournalLayout.sectionGap)
                    Label {
                        Text("Collect through real discoveries. A download adds field-guide pages, never birds: a bird joins your collection only when you add a sighting.")
                    } icon: {
                        Image(systemName: "map").foregroundStyle(.tint)
                    }
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.inkSecondary)
                    .padding(.top, 12)
                    SectionTitle("Field guide")
                    Text("\(entries.count) birds with photos and field notes on this iPhone. Any bird BirdNET knows can still be identified by name.")
                        .font(JournalFont.supporting)
                        .foregroundStyle(Color.inkSecondary)
                        .padding(.top, 4)
                }
                if shown.isEmpty {
                    if entries.isEmpty {
                        StateNotice(
                            "No field guide yet",
                            message: "No field guide is on this iPhone, so there are no pages to browse. Download a set's field guide for its photos, sounds and stories. Listening and identification work without one.",
                            mark: .symbol("map")
                        ) {
                            NavigationLink("See field-guide downloads", value: Route.packs)
                                .buttonStyle(.journalOutlined)
                        }
                    } else if sets.isEmpty {
                        NoSearchMatch(query: query, searches: "Search by a bird's common or scientific name, or a set.") { query = "" }
                            .padding(.top, 12)
                    }
                } else {
                    if !query.isEmpty { SectionTitle("Birds") }
                    LazyVStack(spacing: 0) {
                        ForEach(shown, id: \.species.scientificName) { entry in
                            NavigationLink(value: Route.species(scientificName: entry.species.scientificName, commonName: entry.species.commonName)) {
                                GuideRow(pack: entry.pack, species: entry.species)
                            }
                            .buttonStyle(.plain)
                            RowRule()
                        }
                    }
                    .padding(.top, 12)
                    .holdsPatchLight()
                }
            }
            .padding(.horizontal, JournalLayout.margin)
            .padding(.bottom, JournalLayout.sectionGap)
        }
        #if DEBUG
        .debugScroll(proxy, to: "atlas-new", when: !elsewhere.isEmpty)
        #endif
        }
        .background(Color.paper)
        .navigationTitle("Atlas")
        .navigationSubtitle("Field guide & sets")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search birds or sets")
        #if DEBUG
        .task {
            // Issue #119's screenshots: `-autoQuery <text>` searches once, for the no-match state.
            if let text = UserDefaults.standard.string(forKey: "autoQuery") { query = text }
        }
        #endif
        .task { if library.index == nil { await library.refreshIndex() } }
        .refreshable { await library.refreshIndex() }
    }
}

/// The pack list couldn't be fetched: what still works, and Try again.
struct OfflineNotice: View {
    let hasIndex: Bool
    let retry: () -> Void

    var body: some View {
        ErrorNotice(
            "Couldn't check for sets",
            message: hasIndex
                ? "You may be offline. These are the sets from the last check; downloads on this iPhone, your collection and identification all keep working."
                : "You may be offline. The sets you can download appear once the list comes through; downloads on this iPhone, your collection and identification all keep working.",
            symbol: "wifi.slash"
        ) {
            Button("Try again", action: retry)
        }
        .accessibilityIdentifier("atlas-offline")
    }
}

/// One regional set as a plate on card stock (issue #150, A1): its painting, name and edition, the birder's own progress, "18 of
/// 160 sewn", and "Ready offline" on the Atlas. The tile opens the set's page. The download control is plain iOS, so it sits
/// under the plate, on the page and apart from the link.
struct SetTile: View {
    @Environment(PackLibrary.self) private var library
    let set: PackSet
    let progress: SetProgress
    var opensSet = true

    var body: some View {
        let descriptor = library.index?.descriptor(id: set.id)
        let installed = library.pack(id: set.id) != nil
        let status = descriptor.map(library.status(of:)) ?? (installed ? .bundled : .notInstalled)
        VStack(alignment: .leading, spacing: 10) {
            if opensSet {
                NavigationLink(value: Route.set(id: set.id)) {
                    SetPlate(set: set, progress: progress, showsReadyOffline: installed)
                        .contentShape(Rectangle())
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(SetPlate.spokenTile(set: set, progress: progress, isReadyOffline: installed))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("guide-set-\(set.id)")
            } else {
                SetPlate(set: set, progress: progress)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("set-plate")
            }
            if !installed || Self.isTransferring(status) {
                PackTransferStatus(status: status, descriptor: descriptor)
            }
        }
        // The set's own edition, wherever the Atlas's tile is shown from: its thread, and its download.
        .tint(PatchEdition.tint(setID: set.id))
    }

    static func isTransferring(_ status: PackLibrary.Status) -> Bool {
        switch status {
        case .downloading, .installing, .failed, .updateAvailable: true
        default: false
        }
    }
}

/// Installed content status, in words and a check: kept apart from the birder's progress.
struct ReadyOffline: View {
    /// The tint on the page. On a plate it's the card's ink, which clears the fibre in every edition.
    var ink: Color?

    var body: some View {
        Label("Ready offline", systemImage: "checkmark.circle.fill")
            .font(JournalFont.supporting.weight(.medium))
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(ink.map(AnyShapeStyle.init) ?? AnyShapeStyle(TintShapeStyle.tint))
    }
}

/// The way to the field-guide downloads: what is on the phone, and the storage it takes.
private struct PacksCard: View {
    let library: PackLibrary

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.stack.3d.down.right")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text("Field-guide downloads")
                    .font(JournalFont.rowTitle)
                    .foregroundStyle(Color.ink)
                Text(library.packs.isEmpty ? "Photos, sounds and field notes, ready offline." : "Downloads, updates and storage: \(library.packs.map(\.info.name).joined(separator: ", "))")
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.inkSecondary)
                    .lineLimit(2)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.inkSecondary)
        }
        .padding(16)
        .background(Color.raised, in: RoundedRectangle(cornerRadius: JournalLayout.cornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// One bird in the guide: your patch of it in this pack's set if you have one, else the reference photo (issue #150, V2), then
/// its names and a hint of habitat.
private struct GuideRow: View {
    @Environment(CollectionStore.self) private var collectionStore
    @Environment(\.dynamicTypeSize) private var typeSize
    let pack: SpeciesPack
    let species: PackSpecies

    var body: some View {
        AdaptiveRow(stacked: typeSize.stacksRows) {
            RowPicture(source: .of(species: species, in: pack, collection: collectionStore.collection))
            VStack(alignment: .leading, spacing: 3) {
                Text(species.commonName)
                    .font(JournalFont.rowTitle)
                    .foregroundStyle(Color.ink)
                Text(species.scientificName)
                    .font(JournalFont.scientific)
                    .foregroundStyle(Color.inkSecondary)
                if let habitat = species.habitat, !habitat.isEmpty {
                    Text(habitat.capitalizedFirst)
                        .font(JournalFont.attribution)
                        .foregroundStyle(Color.inkSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.inkSecondary)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
