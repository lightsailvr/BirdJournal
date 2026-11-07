import Album
import Pack
import SwiftData
import SwiftUI

/// The paper card behind a patch (issue #134, guide page 10), top to bottom: the edition line and the collector number, the
/// name in serif with the scientific name in italic, the story title, the lore excerpt, the biology, your history with the
/// bird here (the count, when it was sewn, the latest sightings, each opening its sighting), then the rest of the lore.
/// "All 8 sightings", "AI illustration" and Sources stay in the footer. It scrolls inside the patch's footprint; at
/// accessibility text sizes it grows into a reading view and the page scrolls instead.
struct PaperCardView: View {
    @Environment(PackLibrary.self) private var library
    @Environment(PlaceNames.self) private var places
    let patch: CardCollection.Patch
    /// The patch's sightings, newest first.
    let sightings: [Sighting]
    let name: String
    /// Grows with its text instead of scrolling inside the footprint.
    let isReadingView: Bool

    private static let latestShown = 3

    var body: some View {
        let species = library.species(scientificName: patch.scientificName)?.species
        VStack(spacing: 0) {
            if isReadingView {
                content(species)
            } else {
                ScrollView {
                    content(species)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.visible)
                .accessibilityIdentifier("card-back-scroll")
            }
            footer(hasCredits: species != nil)
        }
        .padding(.top, 22)
        .padding(.horizontal, 7)
        .padding(.bottom, 7)
        .modifier(CardStockSurface())
    }

    private func content(_ species: PackSpecies?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            editionLine
            VStack(spacing: 1) {
                Text(name)
                    .font(CardFont.birdName)
                    .foregroundStyle(Color.cardInk)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("card-name")
                Text(patch.scientificName)
                    .font(CardFont.scientific)
                    .foregroundStyle(Color.cardInkSecondary)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
            story(species)
            let biology = PatchText.biology(species)
            if !biology.isEmpty {
                PaperRule()
                BiologyGrid(stats: biology)
            }
            PaperRule()
            history
            if let lore = species?.lore {
                moreLore(lore)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private var editionLine: some View {
        let heading = CardHeading.accessibilityText(placement: patch.placement).compactMap { $0 }.joined(separator: ", ")
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                Text(PatchText.cardEdition(patch.placement)).fixedSize()
                Spacer(minLength: 8)
                collectorNumber.fixedSize()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(PatchText.cardEdition(patch.placement)).fixedSize(horizontal: false, vertical: true)
                collectorNumber.fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .textCase(.uppercase)
        .font(CardFont.editionCompact)
        .tracking(CardFont.editionCompactTracking)
        .foregroundStyle(Color.cardEdge)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(patch.placement.setID == nil ? "Uncharted, outside every set" : heading)
        .accessibilityIdentifier("card-heading")
    }

    /// "NO. 130 / 160"; nothing outside every set.
    @ViewBuilder private var collectorNumber: some View {
        if case .numbered(_, _, _, let number, let total) = patch.placement {
            Text("No. \(CardPlacement.paddedNumber(number, of: total)) / \(CardPlacement.paddedNumber(total, of: total))")
                .monospacedDigit()
        }
    }

    @ViewBuilder private func story(_ species: PackSpecies?) -> some View {
        if let lore = species?.lore {
            PaperCardStory(lore: lore)
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(patch.count, format: .number)
                    .font(PatchFont.cardCount)
                    .foregroundStyle(Color.cardInk)
                    .accessibilityHidden(true)
                Text(historyLine)
                    .font(.caption)
                    .foregroundStyle(Color.cardInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("\(PatchText.sightings(patch.count)) here, sewn \(PatchText.spokenDate(patch.sewn.confirmedAt))")
                    .accessibilityIdentifier("card-history")
            }
            ForEach(sightings.prefix(Self.latestShown)) { sighting in
                NavigationLink(value: Route.sighting(sighting.persistentModelID)) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(sighting.confirmedAt.formatted(date: .abbreviated, time: .omitted)).fixedSize()
                            Spacer(minLength: 8)
                            ShortFacts(sighting.method.title, places.cardPlace(for: sighting.location)).multilineTextAlignment(.trailing).lineLimit(1)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(sighting.confirmedAt.formatted(date: .abbreviated, time: .omitted))
                            ShortFacts(sighting.method.title, places.cardPlace(for: sighting.location)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(Color.cardInk)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(sighting.confirmedAt.formatted(date: .long, time: .omitted)), \(sighting.method.title), \(places.cardPlace(for: sighting.location))")
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens this sighting.")
                .accessibilityIdentifier("card-history-sighting")
            }
        }
        .task(id: sightings.prefix(Self.latestShown).compactMap(\.location).count) {
            for sighting in sightings.prefix(Self.latestShown) {
                if let location = sighting.location { await places.resolve(location) }
            }
        }
    }

    /// "8 sightings here, sewn Sep 14 in Los Angeles".
    private var historyLine: String {
        let sewn = patch.sewn.confirmedAt.formatted(date: .abbreviated, time: .omitted)
        let here = patch.placement.setID == nil ? "" : " in \(patch.placement.setName)"
        return "\(patch.count == 1 ? "sighting" : "sightings") here, sewn \(sewn)\(here)"
    }

    private func moreLore(_ lore: PackLore) -> some View {
        PaperCardMoreLore(lore: lore)
    }

    /// Stays in view under the scrolling text.
    private func footer(hasCredits: Bool) -> some View {
        let all = PatchText.allSightings(patch.count)
        let hasPainting = library.patchArt(scientificName: patch.scientificName, setID: patch.placement.setID) != nil
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                footerLink(all: all)
                Spacer(minLength: 0)
                footerCredits(hasPainting: hasPainting, hasCredits: hasCredits)
            }
            // Stacked, with no spacer: in a column it would take the height the story needs (half the card at xxLarge).
            VStack(alignment: .leading, spacing: 2) {
                footerLink(all: all)
                footerCredits(hasPainting: hasPainting, hasCredits: hasCredits)
            }
        }
        .font(.caption)
        .foregroundStyle(Color.cardEdge)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }

    private func footerLink(all: String) -> some View {
        NavigationLink(value: Route.sightings(.patch(patch.id))) {
            Label(all, systemImage: "chevron.right")
                .labelStyle(TrailingChevronLabel())
                .frame(minHeight: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityIdentifier("card-all-sightings")
    }

    @ViewBuilder private func footerCredits(hasPainting: Bool, hasCredits: Bool) -> some View {
        if hasPainting {
            Text("AI illustration")
                .fixedSize()
                .accessibilityIdentifier("card-art-credit")
        }
        if hasCredits {
            NavigationLink(value: Route.speciesCredits(scientificName: patch.scientificName)) {
                Label("Sources", systemImage: "chevron.right")
                    .labelStyle(TrailingChevronLabel())
                    .frame(minHeight: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityIdentifier("card-sources")
        }
    }
}

/// The story on a paper card: its title and the lore's excerpt.
private struct PaperCardStory: View {
    let lore: PackLore

    var body: some View {
        VStack(spacing: 6) {
            if let title = lore.title?.nilIfEmpty {
                Text(title)
                    .font(CardFont.storyTitle)
                    .foregroundStyle(Color.cardInk)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("card-story-title")
            }
            if let excerpt = LoreExcerpt.front(lore.text) {
                Text(excerpt)
                    .font(CardFont.lore)
                    .lineSpacing(CardFont.loreLeading)
                    .foregroundStyle(Color.cardInk)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("card-lore-excerpt")
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// The rest of the lore, below the card's history.
private struct PaperCardMoreLore: View {
    let lore: PackLore

    var body: some View {
        if let rest = PatchText.restOfLore(lore.text) {
            PaperRule()
            Text(rest)
                .font(CardFont.lore)
                .lineSpacing(CardFont.loreLeading)
                .foregroundStyle(Color.cardInk)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("card-lore-rest")
        }
    }
}

/// The paper card behind a friend's patch (issue #150, F1): the same printed card, minus what's yours. The edition line, the bird,
/// its story and biology, read from the viewer's own pack, and no history, since these are a friend's sightings and they aren't
/// on this iPhone. Scrolls inside the patch's footprint, or grows at accessibility text sizes, like the birder's own.
struct FriendPaperCard: View {
    @Environment(PackLibrary.self) private var library
    let species: PackSpecies
    /// "Citrus edition, No. 021", if this phone knows the find's set.
    let edition: String?
    let isReadingView: Bool

    var body: some View {
        VStack(spacing: 0) {
            if isReadingView {
                content
            } else {
                ScrollView { content }
                    .scrollBounceBehavior(.basedOnSize)
                    .scrollIndicators(.visible)
                    .accessibilityIdentifier("card-back-scroll")
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                NavigationLink(value: Route.speciesCredits(scientificName: species.scientificName)) {
                    Label("Sources", systemImage: "chevron.right")
                        .labelStyle(TrailingChevronLabel())
                        .frame(minHeight: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityIdentifier("card-sources")
            }
            .font(.caption)
            .foregroundStyle(Color.cardEdge)
            .padding(.horizontal, 14)
            .padding(.top, 2)
            .padding(.bottom, 6)
        }
        .padding(.top, 22)
        .padding(.horizontal, 7)
        .padding(.bottom, 7)
        .modifier(CardStockSurface())
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let edition {
                Text(edition)
                    .textCase(.uppercase)
                    .font(CardFont.editionCompact)
                    .tracking(CardFont.editionCompactTracking)
                    .foregroundStyle(Color.cardEdge)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(edition)
                    .accessibilityIdentifier("card-heading")
            }
            VStack(spacing: 1) {
                Text(species.commonName)
                    .font(CardFont.birdName)
                    .foregroundStyle(Color.cardInk)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("card-name")
                Text(species.scientificName)
                    .font(CardFont.scientific)
                    .foregroundStyle(Color.cardInkSecondary)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
            if let lore = species.lore {
                PaperCardStory(lore: lore)
            }
            let biology = PatchText.biology(species)
            if !biology.isEmpty {
                PaperRule()
                BiologyGrid(stats: biology)
            }
            if let lore = species.lore {
                PaperCardMoreLore(lore: lore)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }
}

/// The word, then a small chevron.
private struct TrailingChevronLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.title
            configuration.icon.imageScale(.small).accessibilityHidden(true)
        }
    }
}

/// A fine rule on the card.
private struct PaperRule: View {
    var body: some View {
        Rectangle().fill(Color.cardEdge.opacity(0.3)).frame(height: 1).accessibilityHidden(true)
    }
}

/// The species' biology in three columns, two as the text grows, one at accessibility sizes: each stat one VoiceOver stop.
private struct BiologyGrid: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let stats: [CardStatsText.Stat]

    var body: some View {
        LazyVGrid(columns: PatchBoardLayout.grid(for: typeSize, spacing: 8), spacing: 8) {
            ForEach(stats, id: \.label) { stat in
                VStack(spacing: 1) {
                    Text(stat.label)
                        .font(.caption2)
                        .foregroundStyle(Color.cardInkSecondary)
                    Text(stat.value)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.cardInk)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(stat.spoken)
                .accessibilityIdentifier("card-stat-\(stat.label.lowercased())")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("card-stats")
    }
}
