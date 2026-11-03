import Album
import Pack
import SwiftData
import SwiftUI

/// The Collection tab (issue #28, renamed from Journal in #117): the collection's cards (issue #51), every sighting by
/// day (the journal), or the distinct species, with search; a card opens the card, a sighting the sighting and a
/// species its gallery (issue #53). The mode picker stays pinned under the title, and the mode, the search, the Cards
/// sort and each mode's scroll offset live in the root's `CollectionState`, so coming back finds them as they were
/// (design guide page 10). Removals can be undone for a few seconds. The first time the collection has a card, a
/// one-time "your collection so far" moment introduces it.
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
    @Bindable var state: CollectionState
    @State private var showsIntro = false
    @State private var position = ScrollPosition(edge: .top)
    /// The offset the scroll view reports, from the top of the content.
    @State private var offset: CGFloat = 0
    /// While a mode's saved offset is being restored, the scroll view's reports are not saved over it.
    @State private var restoring = false
    /// Whether another page covers this one: a page pushed on the tab's stack, or another tab. Offsets reported
    /// meanwhile are not the birder's.
    var isCovered = false

    private var filtered: [Sighting] {
        sightings.filter { Journal.matches(query: state.query, commonName: library.commonName(for: $0), scientificName: $0.scientificName) }
    }

    var body: some View {
        Group {
            if sightings.isEmpty {
                EmptyJournal()
            } else {
                let collection = library.collection(of: sightings)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Text(state.mode == .cards ? collection.summary : Journal.summary(sightingCount: sightings.count, speciesCount: collection.speciesCount))
                            .font(JournalFont.supporting)
                            .foregroundStyle(Color.inkSecondary)
                            .padding(.top, 2)
                            .padding(.bottom, 10)
                        Section {
                            content(collection)
                        } header: {
                            Picker("Show", selection: Binding(get: { state.mode }, set: { switchMode(to: $0) })) {
                                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .padding(.vertical, 8)
                            .background(Color.paper)
                            .accessibilityIdentifier("collection-mode")
                        }
                    }
                    .padding(.horizontal, JournalLayout.margin)
                    .padding(.bottom, JournalLayout.sectionGap)
                }
                .scrollPosition($position)
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.y + geometry.contentInsets.top
                } action: { _, newOffset in
                    offset = newOffset
                    if !isCovered, !restoring { state.offsets[state.mode] = max(newOffset, 0) }
                }
                .onChange(of: isCovered) { _, covered in
                    guard !covered else { return }
                    // Under a card's page the tab bar hides, and at the foot of the grid the offset is clamped to the
                    // taller page; once the way back has settled, put back anything that moved meanwhile.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(450))
                        let saved = state.offsets[state.mode] ?? 0
                        if !isCovered, abs(saved - offset) > 1 { restore(saved) }
                    }
                }
                .onChange(of: state.sort) {
                    // A new order starts from its first card.
                    state.offsets[.cards] = 0
                    restore(0)
                }
                .background(Color.paper)
                .searchable(text: $state.query, prompt: "Search birds")
                #if DEBUG
                .task {
                    // Issue #119's screenshots: `-autoQuery <text>` searches once, for the no-match state.
                    if let text = UserDefaults.standard.string(forKey: "autoQuery") { state.query = text }
                }
                #endif
                .toolbar {
                    if state.mode == .cards {
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                Picker("Sort", selection: $state.sort) {
                                    ForEach(CardSort.allCases) { Text($0.rawValue).tag($0) }
                                }
                            } label: {
                                Label("Sort", systemImage: "arrow.up.arrow.down")
                            }
                            .accessibilityValue(state.sort.rawValue)
                        }
                    }
                }
            }
        }
        .navigationTitle("Collection")
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

    @ViewBuilder
    private func content(_ collection: CardCollection) -> some View {
        if showsIntro {
            CollectionIntroCard(collection: collection) { showsIntro = false }
                .padding(.top, 8)
        }
        let shown = filtered
        if shown.isEmpty {
            NoSearchMatch(query: state.query) { state.query = "" }
                .padding(.top, 24)
        } else {
            switch state.mode {
            case .cards:
                if state.query.isEmpty, let progress = collection.progress.max(by: { $0.collected < $1.collected }) {
                    NavigationLink(value: Route.set(id: progress.setID)) {
                        SetProgressRow(progress: progress, detail: library.sets.first { $0.id == progress.setID }?.edition.name)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("cards-set-progress")
                }
                CardsGrid(sightings: shown, collection: collection, sort: state.sort)
            case .sightings: SightingsByDay(sightings: shown)
            case .species:
                if state.query.isEmpty, !collection.progress.isEmpty || collection.unchartedSpeciesCount > 0 {
                    SetProgressList(collection: collection)
                }
                SpeciesRows(entries: Journal.species(shown))
            }
            Text(state.mode == .cards ? "Every add is a card. Your first of each species is Legendary." : "Your notes, one bird at a time.")
                .multilineTextAlignment(.center)
                .font(JournalFont.supporting)
                .foregroundStyle(Color.inkSecondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 28)
        }
    }

    /// Shows `mode` where it was left: the picker stays pinned, so each mode keeps its own place.
    private func switchMode(to mode: Mode) {
        guard mode != state.mode else { return }
        let saved = state.offsets[mode] ?? 0
        state.mode = mode
        restore(saved)
    }

    /// Scrolls to `saved` once the shown mode has laid out, without saving the offsets passed on the way. The scroll
    /// view's reported offset and `scrollTo(y:)` can differ by the collapsing title's height, so a second step corrects
    /// by whatever the first one missed.
    private func restore(_ saved: CGFloat) {
        restoring = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            position.scrollTo(y: saved)
            try? await Task.sleep(for: .milliseconds(80))
            let missed = saved - offset
            if abs(missed) > 1 {
                position.scrollTo(y: saved + missed)
                try? await Task.sleep(for: .milliseconds(80))
            }
            restoring = false
            state.offsets[state.mode] = max(offset, 0)
        }
    }
}

/// No cards yet (issue #119, design guide page 16): what a card is, and Start listening as the way to the first one.
private struct EmptyJournal: View {
    @Environment(\.openListen) private var openListen

    var body: some View {
        PaperPage {
            StateNotice(
                "No cards yet",
                message: "Start listening, review the birds you hear and add the ones you recognize. Each one becomes a card in your collection, with the day, the place and a note if you like. Your first of each species is Legendary.",
                mark: .drawing
            ) {
                Button {
                    openListen()
                } label: {
                    Label("Start listening", systemImage: "waveform")
                }
                .buttonStyle(.journalPrimary)
                .accessibilityHint("Opens the Listen tab")
            }
            .padding(.top, 12)
        }
    }
}

/// A search with no match (issue #119): what was searched, what the search reads, and the way back to everything.
struct NoSearchMatch: View {
    let query: String
    var searches = "Search by a bird's common or scientific name."
    let clear: () -> Void

    var body: some View {
        StateNotice("No birds match “\(query)”", message: searches, mark: .symbol("magnifyingglass")) {
            Button("Clear search", action: clear)
                .buttonStyle(.journalOutlined)
        }
        .accessibilityIdentifier("no-search-match")
    }
}

/// The Cards view (issue #51): every card newest first (or as `sort` orders them, issue #117), two columns, one at accessibility text sizes, each opening
/// its card (issue #52). Legendary comes from the whole collection, so a search never changes which card is the first.
private struct CardsGrid: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let sightings: [Sighting]
    let collection: CardCollection
    var sort: CardSort = .newest

    var body: some View {
        let byIdentifier = Dictionary(sightings.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        let columns = Array(repeating: GridItem(.flexible(), spacing: JournalLayout.rowGap, alignment: .top), count: typeSize.isAccessibilitySize ? 1 : 2)
        LazyVGrid(columns: columns, spacing: JournalLayout.rowGap) {
            ForEach(sort.ordered(collection.cards, in: collection).compactMap { byIdentifier[$0.identifier] }) { sighting in
                NavigationLink(value: Route.card(sighting.persistentModelID)) {
                    CardTile(sighting: sighting, isLegendary: collection.isLegendary(sighting.identifier), placement: collection.placement(of: sighting.identifier))
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

/// Set progress above the Species list (issue #54): each set the birder has a card in, "Los Angeles · 87 of 160" with
/// a bar, opening the set's page; then how many species are Uncharted.
private struct SetProgressList: View {
    let collection: CardCollection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Sets")
                .font(JournalFont.section)
                .foregroundStyle(Color.ink)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, JournalLayout.sectionGap)
            ForEach(collection.progress) { progress in
                NavigationLink(value: Route.set(id: progress.setID)) {
                    SetProgressRow(progress: progress)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("set-progress-\(progress.setID)")
                RowRule()
            }
            if collection.unchartedSpeciesCount > 0 {
                Text("\(CardPlacement.unchartedTitle) · \(collection.unchartedSpeciesCount) species outside every set")
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.inkSecondary)
                    .padding(.vertical, 12)
                RowRule()
            }
        }
    }
}

/// One set's progress: "Los Angeles · 87 of 160" over a bar.
struct SetProgressRow: View {
    let progress: SetProgress
    var detail: String?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(progress.text)
                    .font(JournalFont.rowTitle)
                    .foregroundStyle(Color.ink)
                if let detail {
                    Text(detail)
                        .font(JournalFont.supporting)
                        .foregroundStyle(Color.inkSecondary)
                }
                ProgressView(value: Double(progress.collected), total: Double(max(progress.total, 1)))
                    .tint(Color.moss)
                    .accessibilityHidden(true)
            }
            Image(systemName: "chevron.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.inkSecondary)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel([progress.name, "\(progress.collected) of \(progress.total) species collected", detail].compactMap { $0 }.joined(separator: ", "))
    }
}

/// The Species list: one row per bird added, with how many cards and when last, each opening its gallery (issue #53).
private struct SpeciesRows: View {
    @Environment(PackLibrary.self) private var library
    @Environment(\.dynamicTypeSize) private var typeSize
    let entries: [Journal.SpeciesEntry]

    /// "today, November 2", "yesterday" or "October 30": the day's title inside a sentence, the month kept capitalised.
    static func lastSeen(_ date: Date) -> String {
        let title = Journal.title(for: date)
        guard title.hasPrefix("Today") || title.hasPrefix("Yesterday"), let first = title.first else { return title }
        return first.lowercased() + title.dropFirst()
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(entries) { entry in
                let reference = library.species(scientificName: entry.scientificName)
                NavigationLink(value: Route.gallery(scientificName: entry.scientificName, commonName: reference?.species.commonName ?? entry.commonName)) {
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
                            Text("\(entry.count) \(entry.count == 1 ? "card" : "cards") · last \(Self.lastSeen(entry.latest.confirmedAt))")
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
