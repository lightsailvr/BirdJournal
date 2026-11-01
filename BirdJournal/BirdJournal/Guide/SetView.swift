import Album
import Pack
import SwiftData
import SwiftUI

/// One set's page (issue #54): its species in collector order, each with its number; a species with a card in the set
/// shows its photo, and one the birder hasn't collected there shows as a silhouette, so the page reads as what is
/// still out there. Reached from the Field Guide's sets and the Journal's set progress; every row opens the bird's
/// profile. Works for a set whose pack isn't downloaded: the names come from the set definition.
struct SetView: View {
    @Environment(PackLibrary.self) private var library
    @Query private var sightings: [Sighting]
    let id: String

    var body: some View {
        if let set = library.sets.first(where: { $0.id == id }) {
            let collection = library.collection(of: sightings)
            let collected = collection.collected(in: set.id)
            let progress = collection.progress(of: set.id)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(set.edition.name) · \(progress.collected) of \(progress.total) collected")
                        .font(JournalFont.supporting)
                        .foregroundStyle(Color.inkSecondary)
                        .padding(.top, 4)
                    if library.pack(id: set.id) == nil {
                        Text("This pack isn't on your iPhone yet. Cards you add in its region still count toward the set.")
                            .font(JournalFont.supporting)
                            .foregroundStyle(Color.inkSecondary)
                            .padding(.top, 8)
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(set.species.enumerated()), id: \.element.scientificName) { offset, species in
                            NavigationLink(value: Route.species(scientificName: species.scientificName, commonName: species.commonName)) {
                                SetSpeciesRow(
                                    number: CardPlacement.paddedNumber(offset + 1, of: set.species.count), species: species,
                                    isCollected: collected.contains(species.scientificName)
                                )
                            }
                            .buttonStyle(.plain)
                            RowRule()
                        }
                    }
                    .padding(.top, 12)
                }
                .padding(.horizontal, JournalLayout.margin)
                .padding(.bottom, JournalLayout.sectionGap)
            }
            .background(Color.paper)
            .navigationTitle(set.name)
        } else {
            ContentUnavailableView("Set not found", systemImage: "square.stack.3d.down.right", description: Text("The pack index no longer lists this set."))
                .background(Color.paper)
        }
    }
}

/// One species of a set: its collector number, its photo once collected (a collected bird whose pack isn't on the
/// phone has no photo, so the row also says Collected) or a silhouette, and its names.
private struct SetSpeciesRow: View {
    @Environment(PackLibrary.self) private var library
    @Environment(\.dynamicTypeSize) private var typeSize
    /// e.g. "021".
    let number: String
    let species: PackSet.Species
    let isCollected: Bool

    var body: some View {
        AdaptiveRow(stacked: typeSize.stacksRows) {
            Group {
                if isCollected {
                    PackImage(url: library.thumbnailURL(scientificName: species.scientificName))
                } else {
                    SpeciesSilhouette()
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: JournalLayout.thumbnailRadius, style: .continuous))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(number)
                    .font(JournalFont.attribution.monospacedDigit())
                    .foregroundStyle(Color.inkSecondary)
                Text(species.commonName)
                    .font(JournalFont.rowTitle)
                    .foregroundStyle(isCollected ? Color.ink : Color.inkSecondary)
                Text(species.scientificName)
                    .font(JournalFont.scientific)
                    .foregroundStyle(Color.inkSecondary)
                if isCollected {
                    Label("Collected", systemImage: "checkmark")
                        .font(JournalFont.attribution.weight(.semibold))
                        .foregroundStyle(Color.mossText)
                } else {
                    Text("Not collected yet")
                        .font(JournalFont.attribution)
                        .foregroundStyle(Color.inkSecondary)
                }
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.inkSecondary)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([number, species.commonName, isCollected ? "collected" : "not collected yet"].joined(separator: ", "))
        .accessibilityIdentifier(isCollected ? "set-species-collected" : "set-species-silhouette")
    }
}

/// A bird not yet collected: a silhouette in the photo's place.
struct SpeciesSilhouette: View {
    var body: some View {
        ZStack {
            Color.raised
            Image(systemName: "bird.fill")
                .resizable()
                .scaledToFit()
                .padding(14)
                .foregroundStyle(Color.inkSecondary.opacity(0.45))
        }
    }
}
