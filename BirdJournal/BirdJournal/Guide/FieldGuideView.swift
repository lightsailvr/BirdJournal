import Album
import Pack
import SwiftData
import SwiftUI

/// The Atlas tab (issue #28's Field Guide, reskinned as the Atlas in #118, design guide pages 4 and 14): the regional
/// sets as tiles with their covers, the ones on this iPhone first and then "Somewhere new", each keeping "Species
/// collected" (the birder's progress) apart from "Ready offline" (the pack on the phone); the way to the bird packs; and
/// every bird the installed packs describe, searchable with the sets by name. A download adds field-guide material,
/// never birds: a bird joins the collection only with a sighting.
struct FieldGuideView: View {
    @Environment(PackLibrary.self) private var library
    @Query private var sightings: [Sighting]
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

    private var shown: [(pack: SpeciesPack, species: PackSpecies)] {
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
        let collection = library.collection(of: sightings)
        let sets = shownSets
        let onPhone = sets.filter { library.pack(id: $0.id) != nil }
        let elsewhere = sets.filter { library.pack(id: $0.id) == nil }
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if library.indexError != nil, !library.isRefreshingIndex {
                    OfflineNotice(hasIndex: library.index != nil) { Task { await library.refreshIndex() } }
                        .padding(.top, 8)
                }
                VStack(spacing: 16) {
                    ForEach(onPhone) { set in
                        SetTile(set: set, progress: collection.progress(of: set.id))
                    }
                }
                .padding(.top, 8)
                if !elsewhere.isEmpty {
                    AtlasHeading(text: "Somewhere new")
                        .id("atlas-new")
                    VStack(spacing: 16) {
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
                        Image(systemName: "map").foregroundStyle(Color.moss)
                    }
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.inkSecondary)
                    .padding(.top, 12)
                    AtlasHeading(text: "Field guide")
                    Text("\(entries.count) birds with photos and field notes on this iPhone. Any bird BirdNET knows can still be identified by name.")
                        .font(JournalFont.supporting)
                        .foregroundStyle(Color.inkSecondary)
                        .padding(.top, 4)
                }
                if shown.isEmpty {
                    if entries.isEmpty {
                        StateNotice(
                            "No field guide yet",
                            message: "No bird pack is on this iPhone, so there are no pages to browse. Download a regional set for its photos, sounds and stories. Listening and identification work without one.",
                            mark: .symbol("map")
                        ) {
                            NavigationLink("See bird packs", value: Route.packs)
                                .buttonStyle(.journalOutlined)
                        }
                    } else if sets.isEmpty {
                        NoSearchMatch(query: query, searches: "Search by a bird's common or scientific name, or a region.") { query = "" }
                            .padding(.top, 12)
                    }
                } else {
                    if !query.isEmpty { AtlasHeading(text: "Birds") }
                    VStack(spacing: 0) {
                        ForEach(shown, id: \.species.scientificName) { entry in
                            NavigationLink(value: Route.species(scientificName: entry.species.scientificName, commonName: entry.species.commonName)) {
                                GuideRow(pack: entry.pack, species: entry.species)
                            }
                            .buttonStyle(.plain)
                            RowRule()
                        }
                    }
                    .padding(.top, 12)
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
        .navigationSubtitle("Field guide & regional sets")
        .searchable(text: $query, prompt: "Search birds or regions")
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

/// A heading on the Atlas: the serif section title, no rule (the tiles carry their own edges).
private struct AtlasHeading: View {
    let text: String

    var body: some View {
        Text(text)
            .font(JournalFont.section)
            .foregroundStyle(Color.ink)
            .padding(.top, JournalLayout.sectionGap)
            .accessibilityAddTraits(.isHeader)
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
                ? "You may be offline. These are the sets from the last check; packs on this iPhone, your collection and identification all keep working."
                : "You may be offline. The sets you can download appear once the list comes through; packs on this iPhone, your collection and identification all keep working.",
            symbol: "wifi.slash"
        ) {
            Button("Try again", action: retry)
        }
        .accessibilityIdentifier("atlas-offline")
    }
}

/// One regional set (design guide page 4): its cover, or the landscape its edition names; the name and edition;
/// "Ready offline" or its download; and the birder's own progress, "18 of 160 species collected". The tile opens the
/// set's page; the download control sits apart from the link.
struct SetTile: View {
    @Environment(PackLibrary.self) private var library
    @Environment(\.dynamicTypeSize) private var typeSize
    let set: PackSet
    let progress: SetProgress
    var opensSet = true

    var body: some View {
        let descriptor = library.index?.descriptor(id: set.id)
        let installed = library.pack(id: set.id) != nil
        let status = descriptor.map(library.status(of:)) ?? (installed ? .bundled : .notInstalled)
        VStack(alignment: .leading, spacing: 0) {
            if opensSet {
                NavigationLink(value: Route.set(id: set.id)) { face(installed: installed, status: status) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("guide-set-\(set.id)")
            } else {
                face(installed: installed, status: status)
            }
            if !installed || Self.isTransferring(status) {
                PackTransferStatus(status: status, descriptor: descriptor)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            }
        }
        .background(Color.raised)
        .clipShape(RoundedRectangle(cornerRadius: JournalLayout.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: JournalLayout.cornerRadius, style: .continuous).strokeBorder(Color.rule, lineWidth: 1))
    }

    static func isTransferring(_ status: PackLibrary.Status) -> Bool {
        switch status {
        case .downloading, .installing, .failed, .updateAvailable: true
        default: false
        }
    }

    private func face(installed: Bool, status: PackLibrary.Status) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SetCoverImage(setID: set.id, edition: set.edition.name)
                .frame(height: 148)
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 8) {
                Text(set.name)
                    .font(JournalFont.title)
                    .foregroundStyle(Color.ink)
                if typeSize.stacksRows {
                    VStack(alignment: .leading, spacing: 4) {
                        editionLine
                        if installed { ReadyOffline() }
                    }
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        editionLine
                        Spacer(minLength: 8)
                        if installed { ReadyOffline() }
                    }
                }
                SpeciesCollected(progress: progress)
            }
            .padding(14)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// "Citrus edition · 160 species".
    private var editionLine: some View {
        Text("\(set.edition.name) · \(set.species.count) species")
            .font(JournalFont.supporting)
            .foregroundStyle(Color.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Installed content status, in words and a check: kept apart from the birder's progress.
struct ReadyOffline: View {
    var body: some View {
        Label("Ready offline", systemImage: "checkmark.circle.fill")
            .font(JournalFont.supporting.weight(.medium))
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(Color.moss)
    }
}

/// Personal progress in a set: a bar and "18 of 160 species collected", with the share.
struct SpeciesCollected: View {
    let progress: SetProgress

    private var fraction: Double { progress.total == 0 ? 0 : Double(progress.collected) / Double(progress.total) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.rule.opacity(0.7))
                    Capsule().fill(Color.moss).frame(width: max(progress.collected > 0 ? 6 : 0, geometry.size.width * fraction))
                }
            }
            .frame(height: 6)
            .accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline) {
                Text("\(progress.collected) of \(progress.total) species collected")
                Spacer(minLength: 8)
                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit()
                    .accessibilityHidden(true)
            }
            .font(JournalFont.supporting)
            .foregroundStyle(Color.inkSecondary)
        }
    }
}

/// The way to the bird packs: what is on the phone, and the storage it takes.
private struct PacksCard: View {
    let library: PackLibrary

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.stack.3d.down.right")
                .font(.title2)
                .foregroundStyle(Color.moss)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text("Bird packs")
                    .font(JournalFont.rowTitle)
                    .foregroundStyle(Color.ink)
                Text(library.packs.isEmpty ? "Photos, sounds and field notes, ready offline." : "Downloads, updates and storage · \(library.packs.map(\.info.name).joined(separator: ", "))")
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

/// One bird in the guide: lens thumbnail, names, a hint of habitat.
private struct GuideRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let pack: SpeciesPack
    let species: PackSpecies

    var body: some View {
        AdaptiveRow(stacked: typeSize.stacksRows) {
            PackImage(url: species.photos.first.map(pack.lensImageURL(for:)))
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: JournalLayout.thumbnailRadius, style: .continuous))
                .accessibilityHidden(true)
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
