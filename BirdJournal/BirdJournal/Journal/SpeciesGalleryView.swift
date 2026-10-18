import Album
import Pack
import SwiftData
import SwiftUI

/// The gallery's browsing state (issue #53), shared with the cards opened from it: Previous and Next follow the
/// gallery's filter and sort, and Back finds the filter, the sort and the last card shown as they were left. Lives as
/// long as the gallery is on the navigation stack.
@Observable
final class GalleryBrowse: Hashable {
    let scientificName: String
    var filter: SpeciesGallery.PlaceFilter = .all
    var sort: SpeciesGallery.Sort = .newest
    /// The card last opened from the gallery, marked there and scrolled to on the way back.
    var selected: UUID?

    init(scientificName: String, selected: UUID? = nil) {
        self.scientificName = scientificName
        self.selected = selected
    }

    /// The species' cards among `sightings` under this filter and sort. A card's place is the name the phone has
    /// for it, else its coordinate to a tenth of a degree until the name arrives, so a few fixes at one spot stay one
    /// place offline; no location is "Place not recorded".
    func gallery(_ sightings: [Sighting], places: PlaceNames) -> SpeciesGallery {
        let cards = sightings
            .filter { $0.scientificName == scientificName }
            .map { sighting in
                let place = sighting.location.map { places.name(for: $0) ?? $0.formatted(fractionDigits: 1, locale: .current) }
                return SpeciesGallery.Card(identifier: sighting.identifier, confirmedAt: sighting.confirmedAt, place: place)
            }
        return SpeciesGallery(cards, filter: filter, sort: sort)
    }

    nonisolated static func == (lhs: GalleryBrowse, rhs: GalleryBrowse) -> Bool { lhs === rhs }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// One species' cards (issue #53, collectible-cards style guide "Species gallery"): "House Finch · 15 cards · 2
/// places" with the first discovery, a place picker and a sort menu, the shown and total counts, and a lazy grid of
/// tiles in two columns (one at accessibility text sizes), each opening its card. Reached from the Journal's Species
/// view, a card's All encounters and the Field Guide.
struct SpeciesGalleryView: View {
    @Environment(PackLibrary.self) private var library
    @Environment(PlaceNames.self) private var places
    @Query(Sighting.newestFirst()) private var sightings: [Sighting]
    let scientificName: String
    let commonName: String
    @State private var browse: GalleryBrowse

    init(scientificName: String, commonName: String, selected: UUID? = nil) {
        self.scientificName = scientificName
        self.commonName = commonName
        _browse = State(initialValue: GalleryBrowse(scientificName: scientificName, selected: selected))
    }

    var body: some View {
        let ofSpecies = sightings.filter { $0.scientificName == scientificName }
        let name = library.species(scientificName: scientificName)?.species.commonName ?? ofSpecies.first?.commonName ?? commonName
        ScrollViewReader { proxy in
            PaperPage {
                VStack(alignment: .leading, spacing: 0) {
                    if ofSpecies.isEmpty {
                        NoCardsYet(scientificName: scientificName, commonName: name)
                    } else {
                        GalleryContents(ofSpecies: ofSpecies, collection: CardCollection(sightings: sightings), commonName: name, browse: browse)
                    }
                    NavigationLink(value: Route.species(scientificName: scientificName, commonName: name)) {
                        Label("Open in Field Guide", systemImage: "book")
                    }
                    .buttonStyle(.journalOutlined)
                    .padding(.top, JournalLayout.sectionGap)
                }
            }
            .onAppear {
                // Back from a card: the card last shown, which Next may have taken off screen.
                if let selected = browse.selected { proxy.scrollTo(selected) }
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: ofSpecies.compactMap(\.location).count) {
            for location in ofSpecies.compactMap(\.location) { await places.resolve(location) }
        }
    }
}

/// The header, the controls and the grid of a species with cards.
private struct GalleryContents: View {
    @Environment(PlaceNames.self) private var places
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The species' sightings.
    let ofSpecies: [Sighting]
    /// The whole collection, which decides the Legendary card.
    let collection: CardCollection
    let commonName: String
    @Bindable var browse: GalleryBrowse

    var body: some View {
        let gallery = browse.gallery(ofSpecies, places: places)
        let byIdentifier = Dictionary(ofSpecies.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        VStack(alignment: .leading, spacing: 4) {
            Text(gallery.title(commonName: commonName))
                .font(JournalFont.section)
                .foregroundStyle(Color.ink)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("gallery-title")
            if let first = gallery.firstDiscovery {
                Text("First discovered \(first.formatted(date: .long, time: .omitted))")
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.inkSecondary)
            }
        }
        .padding(.top, 4)

        AdaptiveRow(stacked: typeSize.stacksRows, spacing: 10) {
            Menu {
                Picker("Place", selection: $browse.filter) {
                    Text("\(SpeciesGallery.PlaceFilter.all.title) · \(gallery.cardCount)").tag(SpeciesGallery.PlaceFilter.all)
                    ForEach(gallery.places) { place in
                        Text("\(place.title) · \(place.count)").tag(place.filter)
                    }
                }
            } label: {
                Label(browse.filter.title, systemImage: "mappin.and.ellipse")
                    .lineLimit(typeSize.stacksRows ? nil : 1)
            }
            .buttonStyle(.journalOutlined)
            .accessibilityLabel("Place")
            .accessibilityValue(browse.filter.title)
            .accessibilityIdentifier("gallery-place")
            Menu {
                Picker("Sort", selection: $browse.sort) {
                    ForEach(SpeciesGallery.Sort.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } label: {
                Label(browse.sort.title, systemImage: "arrow.up.arrow.down")
                    .lineLimit(typeSize.stacksRows ? nil : 1)
            }
            .buttonStyle(.journalOutlined)
            .accessibilityLabel("Sort")
            .accessibilityValue(browse.sort.title)
            .accessibilityIdentifier("gallery-sort")
        }
        .padding(.top, 14)

        Text(gallery.shownText)
            .font(JournalFont.supporting)
            .foregroundStyle(Color.inkSecondary)
            .padding(.top, 12)
            .accessibilityIdentifier("gallery-count")

        if gallery.shown.isEmpty {
            NoMatches { browse.filter = .all }
                .padding(.top, 16)
        } else {
            let columns = Array(repeating: GridItem(.flexible(), spacing: JournalLayout.rowGap, alignment: .top), count: typeSize.isAccessibilitySize ? 1 : 2)
            LazyVGrid(columns: columns, spacing: JournalLayout.rowGap) {
                ForEach(gallery.shown) { card in
                    if let sighting = byIdentifier[card.identifier] {
                        NavigationLink(value: Route.card(sighting.persistentModelID, browse: browse)) {
                            GalleryTile(sighting: sighting, place: card.place, isLegendary: collection.isLegendary(card.identifier), isSelected: browse.selected == card.identifier)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(browse.selected == card.identifier ? .isSelected : [])
                        .accessibilityIdentifier("gallery-tile")
                        .id(card.identifier)
                    }
                }
            }
            .padding(.top, 12)
        }
    }
}

/// A filter that matches no card: say so, and offer the way back to every card.
private struct NoMatches: View {
    let clear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No encounters here yet")
                .font(JournalFont.heading)
                .foregroundStyle(Color.ink)
            Text("None of this bird's cards were made at this place.")
                .font(JournalFont.supporting)
                .foregroundStyle(Color.inkSecondary)
            Button("Clear filters", action: clear)
                .buttonStyle(.journalOutlined)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.raised, in: RoundedRectangle(cornerRadius: JournalLayout.cornerRadius, style: .continuous))
    }
}

/// A species with no cards: the guide entry's photo and names, and the way to Listen.
private struct NoCardsYet: View {
    @Environment(PackLibrary.self) private var library
    @Environment(\.openListen) private var openListen
    let scientificName: String
    let commonName: String

    var body: some View {
        let reference = library.species(scientificName: scientificName)
        VStack(alignment: .leading, spacing: 0) {
            if let reference, let photo = reference.species.photos.first {
                AttributedImage(pack: reference.pack, photo: photo)
                    .padding(.top, 4)
            }
            Text("No cards of \(commonName) yet")
                .font(JournalFont.section)
                .foregroundStyle(Color.ink)
                .padding(.top, 14)
                .accessibilityAddTraits(.isHeader)
            Text(scientificName)
                .font(JournalFont.scientific)
                .foregroundStyle(Color.inkSecondary)
            Text("Add this bird when you hear it on a run, and every sighting of it becomes a card here.")
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
