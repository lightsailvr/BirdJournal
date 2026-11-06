import Album
import Pack
import SwiftData
import SwiftUI

/// The Collection tab (issue #28, renamed from Journal in #117): a felt board of a set's patches (issue #134), every
/// sighting by day (the journal), or the distinct species, with search; a patch opens its page, a sighting the sighting
/// and a species its patches. The mode picker stays pinned under the title, and the mode, the search, the board and each
/// mode's scroll offset live in the root's `CollectionState`, so coming back finds them as they were (design guide page
/// 10). Removals can be undone for a few seconds. The first time the collection has a patch, a one-time "your collection
/// so far" moment introduces it.
struct JournalView: View {
    enum Mode: String, CaseIterable, Identifiable {
        /// The patches (issue #132); the case keeps its name from when they were cards.
        case cards = "Patches"
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
                            .foregroundStyle(state.mode == .cards ? Color.ink : Color.inkSecondary)
                            .boardLabel(isOnBoard: state.mode == .cards)
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
                            .background {
                                if state.mode == .cards { BoardMaterial() } else { Color.paper }
                            }
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
                .onChange(of: state.board) {
                    // Another board starts from its first patch.
                    state.offsets[.cards] = 0
                    restore(0)
                }
                .background {
                    if state.mode == .cards { BoardMaterial().ignoresSafeArea() } else { Color.paper.ignoresSafeArea() }
                }
                .searchable(text: $state.query, prompt: "Search birds")
                #if DEBUG
                .task {
                    // Issue #119's screenshots: `-autoQuery <text>` searches once, for the no-match state.
                    if let text = UserDefaults.standard.string(forKey: "autoQuery") { state.query = text }
                    // Issue #138's: `-autoBoard uncharted` opens the Uncharted board.
                    if UserDefaults.standard.string(forKey: "autoBoard") == "uncharted" { state.board = .uncharted }
                }
                #endif
                .toolbar {
                    if state.mode == .cards, state.query.isEmpty, boards(collection).count > 1 {
                        ToolbarItem(placement: .topBarTrailing) {
                            let shown = shownBoard(collection)
                            Menu {
                                Picker("Set", selection: Binding(get: { shown }, set: { state.board = $0 })) {
                                    ForEach(boards(collection), id: \.self) { board in
                                        Text(boardMenuTitle(board, collection)).tag(board)
                                    }
                                }
                            } label: {
                                Label("Set", systemImage: "square.stack")
                            }
                            .accessibilityValue(boardTitle(shown))
                            .accessibilityIdentifier("collection-board")
                        }
                    }
                }
            }
        }
        .navigationTitle("Collection")
        .task(id: sightings.isEmpty) {
            // The sightings the birder had before the collection existed become their patches in one moment.
            let intro = CollectionIntro()
            if intro.shouldShow(patchCount: sightings.count) {
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
        if state.mode == .cards {
            patches(collection)
        } else if shown.isEmpty {
            NoSearchMatch(query: state.query) { state.query = "" }
                .padding(.top, 24)
        } else {
            if state.mode == .sightings {
                SightingsByDay(sightings: shown)
            } else {
                if state.query.isEmpty, !collection.progress.isEmpty || collection.unchartedSpeciesCount > 0 {
                    SetProgressList(collection: collection)
                }
                SpeciesRows(entries: Journal.species(shown))
            }
        }
    }

    /// The Patches mode: the chosen board's patches under its progress, or, while searching, the matches on every board.
    @ViewBuilder
    private func patches(_ collection: CardCollection) -> some View {
        if state.query.isEmpty {
            switch shownBoard(collection) {
            case .set(let id):
                if let set = library.sets.first(where: { $0.id == id }) {
                    NavigationLink(value: Route.set(id: set.id)) {
                        SetProgressRow(progress: collection.progress(of: set.id), detail: set.edition.name, detailInk: .ink)
                            .boardLabel(horizontal: 10, vertical: 2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("cards-set-progress")
                    PatchBoard(patches: collection.patches(in: set.id))
                }
            case .uncharted:
                Text("\(CardPlacement.unchartedTitle), \(collection.unchartedPatches.count) outside every set")
                    .font(JournalFont.rowTitle)
                    .foregroundStyle(Color.ink)
                    .boardLabel()
                    .padding(.vertical, 12)
                PatchBoard(patches: collection.unchartedPatches)
            }
        } else {
            searchResults(collection)
        }
        Text("One patch for every bird, in every place you find it.")
            .multilineTextAlignment(.center)
            .font(JournalFont.supporting)
            .foregroundStyle(Color.ink)
            .boardLabel()
            .frame(maxWidth: .infinity)
            .padding(.top, 28)
    }

    /// A search reads every board, so a patch sewn in another place is still found.
    @ViewBuilder
    private func searchResults(_ collection: CardCollection) -> some View {
        let groups = boards(collection).compactMap { board -> (board: BoardChoice, patches: [CardCollection.Patch])? in
            let all: [CardCollection.Patch]
            switch board {
            case .set(let id): all = collection.patches(in: id)
            case .uncharted: all = collection.unchartedPatches
            }
            let kept = all.filter { Journal.matches(query: state.query, commonName: PatchText.name(of: $0, library: library), scientificName: $0.scientificName) }
            return kept.isEmpty ? nil : (board, kept)
        }
        if groups.isEmpty {
            NoSearchMatch(query: state.query, searches: "Search your patches by a bird's common or scientific name.", messageInk: .ink) { state.query = "" }
                .boardLabel(horizontal: 16, vertical: 4)
                .padding(.top, 24)
        } else {
            ForEach(groups, id: \.board) { group in
                Text(boardTitle(group.board))
                    .font(JournalFont.rowTitle)
                    .foregroundStyle(Color.ink)
                    .boardLabel()
                    .padding(.vertical, 10)
                    .accessibilityAddTraits(.isHeader)
                PatchBoard(patches: group.patches)
            }
        }
    }

    /// The boards with a patch on them: there's nothing to show on any other.
    private func boards(_ collection: CardCollection) -> [BoardChoice] {
        library.sets.filter { collection.progress(of: $0.id).collected > 0 }.map { BoardChoice.set(id: $0.id) }
            + (collection.unchartedPatches.isEmpty ? [] : [.uncharted])
    }

    /// The board to show: the one chosen while it still has a patch, else the place of the newest sighting (the set you're
    /// in, guide page 6).
    private func shownBoard(_ collection: CardCollection) -> BoardChoice {
        let boards = boards(collection)
        if let board = state.board, boards.contains(board) { return board }
        if let newest = sightings.first, let setID = collection.placement(of: newest.identifier)?.setID { return .set(id: setID) }
        return boards.first ?? .uncharted
    }

    private func boardMenuTitle(_ board: BoardChoice, _ collection: CardCollection) -> String {
        switch board {
        case .set(let id): "\(boardTitle(board)), \(collection.progress(of: id).collected)"
        case .uncharted: "\(boardTitle(board)), \(collection.unchartedPatches.count)"
        }
    }

    private func boardTitle(_ board: BoardChoice) -> String {
        switch board {
        case .set(let id): library.sets.first { $0.id == id }?.name ?? id
        case .uncharted: CardPlacement.unchartedTitle
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

/// An empty collection (issues #119, #132, #138): the bare felt and "Your first patch is a bird away." It shows no patterns
/// and no blank, since a bird you haven't found has no patch (DECISIONS.md, issue #138). Start listening is the way to the
/// first patch, and the Atlas is where the birds still to find are.
private struct EmptyJournal: View {
    @Environment(\.openListen) private var openListen
    @Environment(\.openAtlas) private var openAtlas

    var body: some View {
        ScrollView {
            StateNotice(
                "Your first patch is a bird away.",
                message: "Start listening, review the birds you hear and add the ones you recognize. The first time you add a bird in a place, you sew its patch; every sighting after adds to its count.",
                mark: .drawing,
                messageInk: .ink
            ) {
                VStack(spacing: 10) {
                    Button {
                        openListen()
                    } label: {
                        Label("Start listening", systemImage: "waveform")
                    }
                    .buttonStyle(.journalPrimary)
                    .accessibilityHint("Opens the Listen tab")
                    .accessibilityIdentifier("empty-start-listening")
                    Button {
                        openAtlas()
                    } label: {
                        Label("See the birds to find", systemImage: "book")
                    }
                    .buttonStyle(.journalOutlined)
                    .accessibilityHint("Opens the Atlas")
                    .accessibilityIdentifier("empty-open-atlas")
                }
            }
            .boardLabel(horizontal: 16, vertical: 4)
            .padding(.horizontal, JournalLayout.margin)
            .padding(.top, 12)
            .padding(.bottom, JournalLayout.sectionGap)
        }
        .patchSheetBackground()
    }
}

/// A search with no match (issue #119): what was searched, what the search reads, and the way back to everything.
struct NoSearchMatch: View {
    let query: String
    var searches = "Search by a bird's common or scientific name."
    var messageInk: Color = .inkSecondary
    let clear: () -> Void

    var body: some View {
        StateNotice("No birds match “\(query)”", message: searches, mark: .symbol("magnifyingglass"), messageInk: messageInk) {
            Button("Clear search", action: clear)
                .buttonStyle(.journalOutlined)
        }
        .accessibilityIdentifier("no-search-match")
    }
}

/// The one-time "your collection so far" moment: what the birder's sightings became, and what a patch is.
private struct CollectionIntroCard: View {
    let collection: CardCollection
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Your collection so far", top: 0)
            Text("\(collection.patchesText) of \(collection.speciesCount) species. The first time you add a bird in a place, you sew its patch; every sighting after adds to its count.")
                .font(JournalFont.body)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            Button("Got it", action: dismiss)
                .buttonStyle(.journalOutlined)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.moss.opacity(0.1), in: RoundedRectangle(cornerRadius: JournalLayout.cornerRadius, style: .continuous))
        .boardLabel(horizontal: 0, vertical: 0)
    }
}

/// The Sightings list: a heading per day with the place under it when the day's sightings share one.
private struct SightingsByDay: View {
    @Environment(PlaceNames.self) private var places
    let sightings: [Sighting]

    var body: some View {
        ForEach(Journal.days(sightings)) { day in
            VStack(alignment: .leading, spacing: 2) {
                SectionTitle(Journal.title(for: day.start), top: 0)
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
                Text("\(showsDate ? sighting.confirmedAt.formatted(date: .abbreviated, time: .shortened) : sighting.confirmedAt.formatted(date: .omitted, time: .shortened)), \(sighting.source == .glasses ? "added from glasses" : "added from iPhone")")
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

/// Set progress above the Species list (issue #54): each set the birder has a patch in, "Los Angeles, 87 of 160" with
/// a bar, opening the set's page; then how many species are Uncharted.
private struct SetProgressList: View {
    let collection: CardCollection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle("Sets")
            ForEach(collection.progress) { progress in
                NavigationLink(value: Route.set(id: progress.setID)) {
                    SetProgressRow(progress: progress)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("set-progress-\(progress.setID)")
                RowRule()
            }
            if collection.unchartedSpeciesCount > 0 {
                Text("\(CardPlacement.unchartedTitle), \(collection.unchartedSpeciesCount) species outside every set")
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.inkSecondary)
                    .padding(.vertical, 12)
                RowRule()
            }
        }
    }
}

/// One set's progress: "Los Angeles, 87 of 160" over a bar.
struct SetProgressRow: View {
    let progress: SetProgress
    var detail: String?
    /// The quieter words: on a material they stay in the full ink (`TokenPairingTests`).
    var detailInk: Color = .inkSecondary

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(progress.text)
                    .font(JournalFont.rowTitle)
                    .foregroundStyle(Color.ink)
                if let detail {
                    Text(detail)
                        .font(JournalFont.supporting)
                        .foregroundStyle(detailInk)
                }
                ProgressView(value: Double(progress.collected), total: Double(max(progress.total, 1)))
                    .tint(Color.moss)
                    .accessibilityHidden(true)
            }
            Image(systemName: "chevron.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(detailInk)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel([progress.name, "\(progress.collected) of \(progress.total) sewn", detail].compactMap { $0 }.joined(separator: ", "))
    }
}

/// The Species list: one row per bird added, with how many sightings and when last, each opening its patches (issue #134).
private struct SpeciesRows: View {
    @Environment(PackLibrary.self) private var library
    @Environment(\.dynamicTypeSize) private var typeSize
    let entries: [Journal.SpeciesEntry]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(entries) { entry in
                let reference = library.species(scientificName: entry.scientificName)
                NavigationLink(value: Route.speciesPatches(scientificName: entry.scientificName, commonName: reference?.species.commonName ?? entry.commonName)) {
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
                            Text("\(entry.count) \(entry.count == 1 ? "sighting" : "sightings"), last \(SpeciesRowsText.lastSeen(entry.latest.confirmedAt))")
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

enum SpeciesRowsText {
    /// "today, November 2", "yesterday" or "October 30": the day's title inside a sentence, the month kept capitalised.
    static func lastSeen(_ date: Date) -> String {
        let title = Journal.title(for: date)
        guard title.hasPrefix("Today") || title.hasPrefix("Yesterday"), let first = title.first else { return title }
        return first.lowercased() + title.dropFirst()
    }
}
