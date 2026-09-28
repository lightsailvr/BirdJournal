import Album
import Pack
import SwiftUI

/// The Field Guide tab (issue #28): every bird the installed packs describe, searchable by common or scientific name,
/// with the way to the bird packs.
struct FieldGuideView: View {
    @Environment(PackLibrary.self) private var library
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if query.isEmpty {
                    NavigationLink(value: Route.packs) {
                        PacksCard(library: library)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                    Text("Available offline")
                        .font(JournalFont.section)
                        .foregroundStyle(Color.ink)
                        .padding(.top, JournalLayout.sectionGap)
                        .accessibilityAddTraits(.isHeader)
                    Text("\(entries.count) birds with photos and field notes on this iPhone. Any bird BirdNET knows can still be identified by name.")
                        .font(JournalFont.supporting)
                        .foregroundStyle(Color.inkSecondary)
                        .padding(.top, 4)
                }
                if shown.isEmpty {
                    if entries.isEmpty {
                        Text("No bird pack is installed, so there is nothing to browse yet. Download one under Bird packs.")
                            .font(JournalFont.body)
                            .foregroundStyle(Color.inkSecondary)
                            .padding(.top, 20)
                    } else {
                        ContentUnavailableView.search(text: query)
                            .padding(.top, 40)
                    }
                } else {
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
        .background(Color.paper)
        .navigationTitle("Field Guide")
        .searchable(text: $query, prompt: "Common or scientific name")
    }
}

/// The card at the top of the guide: what is on the phone, and the way to more.
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
                Text(library.packs.isEmpty ? "Photos and field notes, ready offline." : library.packs.map(\.info.name).joined(separator: ", "))
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
