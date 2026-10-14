import Album
import Pack
import SwiftData
import SwiftUI

/// The Journal tab (issue #28): the collection's cards (issue #51), every sighting by day, or the distinct species,
/// with search; each card or row opens the sighting. Removals can be undone for a few seconds. The first time the
/// collection has a card, a one-time "your collection so far" moment introduces it.
struct JournalView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case cards = "Cards"
        case sightings = "Sightings"
        case species = "Species"
        var id: Self { self }
    }

    @Query(Sighting.newestFirst()) private var sightings: [Sighting]
    @Environment(PackLibrary.self) private var library
    @Environment(JournalEdits.self) private var edits
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var mode: Mode
    @State private var query = ""
    @State private var showsIntro = false

    private var filtered: [Sighting] {
        sightings.filter { Journal.matches(query: query, commonName: library.commonName(for: $0), scientificName: $0.scientificName) }
    }

    var body: some View {
        Group {
            if sightings.isEmpty {
                EmptyJournal()
            } else {
                let collection = CardCollection(sightings: sightings)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Picker("Show", selection: $mode) {
                            ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .padding(.top, 2)
                        Text(mode == .cards ? collection.summary : Journal.summary(sightingCount: sightings.count, speciesCount: collection.speciesCount))
                            .font(JournalFont.supporting)
                            .foregroundStyle(Color.inkSecondary)
                            .padding(.top, 12)
                        if showsIntro {
                            CollectionIntroCard(collection: collection) { showsIntro = false }
                                .padding(.top, 16)
                        }

                        let shown = filtered
                        if shown.isEmpty {
                            ContentUnavailableView.search(text: query)
                                .padding(.top, 40)
                        } else {
                            switch mode {
                            case .cards: CardsGrid(sightings: shown, collection: collection)
                            case .sightings: SightingsByDay(sightings: shown)
                            case .species: SpeciesRows(entries: Journal.species(shown))
                            }
                            Text(mode == .cards ? "Every add is a card. Your first of each species is Legendary." : "Your notes, one bird at a time.")
                                .multilineTextAlignment(.center)
                                .font(JournalFont.supporting)
                                .foregroundStyle(Color.inkSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 28)
                        }
                    }
                    .padding(.horizontal, JournalLayout.margin)
                    .padding(.bottom, JournalLayout.sectionGap)
                }
                .background(Color.paper)
                .searchable(text: $query, prompt: "Search birds")
            }
        }
        .navigationTitle("Journal")
        .task(id: sightings.isEmpty) {
            // The sightings the birder had before cards existed become their collection in one moment.
            let intro = CollectionIntro()
            if intro.shouldShow(cardCount: sightings.count) {
                showsIntro = true
                intro.markShown()
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let removed = edits.pendingRemoval {
                Toast(text: "Removed \(removed.commonName)", undo: { edits.undoRemoval() })
                    .padding(.bottom, 8)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .default, value: edits.pendingRemoval)
    }
}

private struct EmptyJournal: View {
    var body: some View {
        PaperPage {
            VStack(alignment: .leading, spacing: 14) {
                PerchedBirdDrawing()
                    .frame(height: 110)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 30)
                    .accessibilityHidden(true)
                Text("Nothing here yet")
                    .font(JournalFont.section)
                    .foregroundStyle(Color.ink)
                    .frame(maxWidth: .infinity)
                Text("Start listening, review the birds you hear and add the ones you recognize. Each one becomes a card in your collection, with the day, the place and a note if you like. Your first of each species is Legendary.")
                    .font(JournalFont.body)
                    .foregroundStyle(Color.inkSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

/// The Cards view (issue #51): every card newest first, two columns, one at accessibility text sizes, each opening
/// its sighting. Legendary comes from the whole collection, so a search never changes which card is the first.
private struct CardsGrid: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let sightings: [Sighting]
    let collection: CardCollection

    var body: some View {
        let byIdentifier = Dictionary(sightings.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        let columns = Array(repeating: GridItem(.flexible(), spacing: JournalLayout.rowGap, alignment: .top), count: typeSize.isAccessibilitySize ? 1 : 2)
        LazyVGrid(columns: columns, spacing: JournalLayout.rowGap) {
            ForEach(collection.cards.compactMap { byIdentifier[$0.identifier] }) { sighting in
                NavigationLink(value: Route.sighting(sighting.persistentModelID)) {
                    CardTile(sighting: sighting, isLegendary: collection.isLegendary(sighting.identifier))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 16)
    }
}

/// The one-time "your collection so far" moment: what the birder's sightings became, and what Legendary means.
private struct CollectionIntroCard: View {
    let collection: CardCollection
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("Your collection so far")
                    .font(JournalFont.section)
                    .foregroundStyle(Color.ink)
            } icon: {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.goldInk)
                    .accessibilityHidden(true)
            }
            .accessibilityAddTraits(.isHeader)
            Text("\(collection.cardsText) of \(collection.speciesCount) species. Every bird you add is a card, and your earliest card of each species is Legendary, with a gold frame.")
                .font(JournalFont.body)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            Button("Got it", action: dismiss)
                .buttonStyle(.journalOutlined)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.goldWash, in: RoundedRectangle(cornerRadius: JournalLayout.cornerRadius, style: .continuous))
    }
}

/// The Sightings list: a heading per day with the place under it when the day's sightings share one.
private struct SightingsByDay: View {
    @Environment(PlaceNames.self) private var places
    let sightings: [Sighting]

    var body: some View {
        ForEach(Journal.days(sightings)) { day in
            VStack(alignment: .leading, spacing: 2) {
                Text(Journal.title(for: day.start))
                    .font(JournalFont.section)
                    .foregroundStyle(Color.ink)
                    .accessibilityAddTraits(.isHeader)
                if let place = sharedPlace(day) {
                    Text(place)
                        .font(JournalFont.supporting)
                        .foregroundStyle(Color.inkSecondary)
                }
            }
            .padding(.top, JournalLayout.sectionGap)
            VStack(spacing: 0) {
                ForEach(day.sightings) { sighting in
                    NavigationLink(value: Route.sighting(sighting.persistentModelID)) {
                        SightingRow(sighting: sighting)
                    }
                    .buttonStyle(.plain)
                    RowRule()
                }
            }
            .padding(.top, 10)
        }
    }

    private func sharedPlace(_ day: Journal.Day) -> String? {
        let names = Set(day.sightings.compactMap { sighting in sighting.location.flatMap(places.name(for:)) })
        return names.count == 1 ? names.first : nil
    }
}

/// One sighting: the glasses snapshot when there is one, else the reference photo, then the name, the time and the
/// source, and which kind of picture it is.
struct SightingRow: View {
    @Environment(PackLibrary.self) private var library
    @Environment(PlaceNames.self) private var places
    @Environment(\.dynamicTypeSize) private var typeSize
    let sighting: Sighting
    var showsDate = false

    var body: some View {
        let reference = library.species(scientificName: sighting.scientificName)
        AdaptiveRow(stacked: typeSize.stacksRows) {
            Group {
                if sighting.frameImagePath != nil {
                    FrameImage(frameImagePath: sighting.frameImagePath)
                } else {
                    PackImage(url: reference.flatMap { found in found.species.photos.first.map(found.pack.lensImageURL(for:)) })
                }
            }
            .frame(width: 84, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: JournalLayout.thumbnailRadius, style: .continuous))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(library.commonName(for: sighting))
                    .font(JournalFont.heading)
                    .foregroundStyle(Color.ink)
                Text("\(showsDate ? sighting.confirmedAt.formatted(date: .abbreviated, time: .shortened) : sighting.confirmedAt.formatted(date: .omitted, time: .shortened)) · \(sighting.source == .glasses ? "Added from glasses" : "Added from iPhone")")
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.inkSecondary)
                Text(sighting.frameImagePath != nil ? "Your glasses snapshot" : (reference?.species.photos.isEmpty == false ? "Reference photo" : "No photo"))
                    .font(JournalFont.attribution)
                    .foregroundStyle(Color.inkSecondary)
                if let note = sighting.note, !note.isEmpty {
                    Text(note)
                        .font(JournalFont.attribution)
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.inkSecondary)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .task(id: sighting.location) {
            if let location = sighting.location { await places.resolve(location) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The Species list: one row per bird added, with how often and when last.
private struct SpeciesRows: View {
    @Environment(PackLibrary.self) private var library
    @Environment(\.dynamicTypeSize) private var typeSize
    let entries: [Journal.SpeciesEntry]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(entries) { entry in
                let reference = library.species(scientificName: entry.scientificName)
                NavigationLink(value: Route.journalSpecies(speciesID: entry.speciesID)) {
                    AdaptiveRow(stacked: typeSize.stacksRows) {
                        PackImage(url: reference.flatMap { found in found.species.photos.first.map(found.pack.lensImageURL(for:)) })
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: JournalLayout.thumbnailRadius, style: .continuous))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(reference?.species.commonName ?? entry.commonName)
                                .font(JournalFont.rowTitle)
                                .foregroundStyle(Color.ink)
                            Text(entry.scientificName)
                                .font(JournalFont.scientific)
                                .foregroundStyle(Color.inkSecondary)
                            Text("\(entry.count) \(entry.count == 1 ? "sighting" : "sightings") · last \(Journal.title(for: entry.latest.confirmedAt).lowercased())")
                                .font(JournalFont.supporting)
                                .foregroundStyle(Color.inkSecondary)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.inkSecondary)
                    }
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                RowRule()
            }
        }
        .padding(.top, 16)
    }
}

/// One species in the journal: a short profile up top, then its sightings.
struct SpeciesJournalView: View {
    @Environment(PackLibrary.self) private var library
    let speciesID: String
    @Query private var sightings: [Sighting]

    init(speciesID: String) {
        self.speciesID = speciesID
        _sightings = Query(filter: #Predicate<Sighting> { $0.speciesID == speciesID }, sort: \.confirmedAt, order: .reverse)
    }

    private var scientificName: String { String(speciesID.prefix { $0 != "_" }) }
    private var labelCommonName: String {
        guard let underscore = speciesID.firstIndex(of: "_") else { return speciesID }
        return String(speciesID[speciesID.index(after: underscore)...])
    }

    var body: some View {
        let reference = library.species(scientificName: scientificName)
        PaperPage {
            VStack(alignment: .leading, spacing: 0) {
                if let reference, let photo = reference.species.photos.first {
                    AttributedImage(pack: reference.pack, photo: photo)
                        .padding(.top, 4)
                }
                Text(reference?.species.commonName ?? labelCommonName)
                    .font(JournalFont.title)
                    .foregroundStyle(Color.ink)
                    .padding(.top, 14)
                Text(scientificName)
                    .font(JournalFont.scientific)
                    .foregroundStyle(Color.inkSecondary)
                if let summary = reference?.species.summary, !summary.isEmpty {
                    Text(summary)
                        .font(JournalFont.body)
                        .foregroundStyle(Color.ink)
                        .padding(.top, 12)
                }
                NavigationLink(value: Route.species(scientificName: scientificName, commonName: reference?.species.commonName ?? labelCommonName)) {
                    Label("Open in Field Guide", systemImage: "book")
                }
                .buttonStyle(.journalOutlined)
                .padding(.top, 12)

                SectionTitle(text: "\(sightings.count) \(sightings.count == 1 ? "sighting" : "sightings")")
                VStack(spacing: 0) {
                    ForEach(sightings) { sighting in
                        NavigationLink(value: Route.sighting(sighting.persistentModelID)) {
                            SightingRow(sighting: sighting, showsDate: true)
                        }
                        .buttonStyle(.plain)
                        RowRule()
                    }
                }
                .padding(.top, 8)
            }
        }
        .navigationTitle(reference?.species.commonName ?? labelCommonName)
        .navigationBarTitleDisplayMode(.inline)
    }
}
