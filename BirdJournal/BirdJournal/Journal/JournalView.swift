import Album
import Pack
import SwiftData
import SwiftUI
import UIKit

/// The Collection tab (issue #28, renamed from Journal in #117): a felt board of a set's patches (issue #134), every
/// sighting by day (the journal), or the distinct species, with search; a patch opens its page, a sighting the sighting
/// and a species its patches. The mode picker stays pinned under the title, and the mode, the search, the board and each
/// mode's search-return offset live in the root's `CollectionState`, so coming back finds them as they were (design guide page
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

    @Environment(CollectionStore.self) private var collectionStore
    @Query(Sighting.newestFirst()) private var sightings: [Sighting]
    /// The photos waiting for a name (issue #188): "To name", at the top of the Sightings. They are no sightings.
    @Query(Capture.newestFirst()) private var captures: [Capture]
    @State private var naming: UnnamedSighting?
    /// The add last made from "To name", as the naming sheet reported it: its acknowledgment shows here, where it was made.
    /// No other add's does.
    @State private var namedHere: RunSightings.Addition?
    @Environment(PackLibrary.self) private var library
    @Environment(JournalEdits.self) private var edits
    @Environment(ListeningCoordinator.self) private var run
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { PatchMotion.reduces(system: systemReduceMotion) }
    @Bindable var state: CollectionState
    @State private var showsIntro = false
    @State private var position = ScrollPosition(edge: .top)
    /// The offset the scroll view reports, from the top of the content.
    @State private var offset: CGFloat = 0
    /// While a mode's saved offset is being restored, the scroll view's reports are not saved over it.
    @State private var restoring = false
    @AccessibilityFocusState private var magnifierHasFocus: Bool
    /// The keyboard's on its way down. At a board's foot that pulls the offset back just after the restore has saved it, so the wrong
    /// place would be remembered: the same room a patch's page gets holds it until the keyboard's gone.
    @State private var isClosingSearch = false
    /// The restore under way.
    @State private var settling: Task<Void, Never>?
    /// Whether another page covers this one: a page pushed on the tab's stack, or another tab. Offsets reported
    /// meanwhile are not the birder's.
    var isCovered = false

    private var filtered: [Sighting] {
        sightings.filter { Journal.matches(query: state.query, commonName: library.commonName(for: $0), scientificName: $0.scientificName) }
    }

    var body: some View {
        Group {
            if sightings.isEmpty {
                EmptyJournal(unnamed: captures.map(UnnamedSighting.init)) { naming = $0 }
            } else {
                let collection = collectionStore.collection
                // The stack is what keeps its identity. An id on the scroll view alone is the identity of everything hung on it
                // below as well, so each mode change made a new picker, surface and toolbar, and the surface cut instead of fading.
                ZStack {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            content(collection)
                        }
                        .padding(.horizontal, JournalLayout.margin)
                        .padding(.bottom, JournalLayout.sectionGap)
                    }
                    // A new native scroll view starts at the top before its lazy stack lays out (issue #180). Only the
                    // scrolling content changes identity: the pinned picker, search field and navigation bar stay put.
                    .id(state.mode)
                    .transition(modeContentTransition)
                }
                // Outside the scrolling content, under a title that doesn't collapse: the picker has nothing to ride on, so whatever a
                // mode change does to the content or the offset, it stays exactly where it is.
                .safeAreaBar(edge: .top) {
                    VStack(alignment: .leading, spacing: 0) {
                        if state.isSearching {
                            HStack(spacing: 8) {
                                CollectionSearchField(query: $state.query, wantsFocus: $state.searchWantsFocus)
                                    .frame(height: 40)
                                Button(action: endSearch) {
                                    Image(systemName: "xmark")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.tint)
                                        // The mark stays inside its circle at any text size; the circle's the target.
                                        .dynamicTypeSize(...DynamicTypeSize.xLarge)
                                        .frame(width: 44, height: 44)
                                        .glassEffect(.regular.interactive(), in: .circle)
                                        .contentShape(.circle)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Close search")
                                .accessibilityIdentifier("collection-search-close")
                            }
                            // The height of the row it stands in for, so the picker stays where it was.
                            .frame(height: 54)
                        }
                        Picker("Show", selection: Binding(get: { state.mode }, set: { switchMode(to: $0) })) {
                            ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .padding(.vertical, 8)
                        .accessibilityIdentifier("collection-mode")
                        if state.mode == .cards, state.query.isEmpty, boards(collection).count > 1 {
                            // In reach from anywhere on a board.
                            setMenu(shownBoard(collection), collection)
                                .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, JournalLayout.margin)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background { ModeSurface(mode: state.mode).ignoresSafeArea(edges: .top) }
                    // The bar's empty parts don't reach the tiles scrolling under them.
                    .contentShape(Rectangle())
                }
                .scrollEdgeEffectHidden(true, for: .top)
                .scrollPosition($position)
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.y + geometry.contentInsets.top
                } action: { _, newOffset in
                    offset = newOffset
                    if !isCovered, !restoring { state.offsets[state.mode] = max(newOffset, 0) }
                }
                .onScrollPhaseChange { _, phase in
                    // The birder's own scroll wins over putting one back.
                    if phase == .interacting { stopRestoring() }
                }
                .onChange(of: isCovered) { _, covered in
                    if covered { stopRestoring() }
                }
                .keepsItsFootUnderAPage(isCovered: isCovered || isClosingSearch)
                .onChange(of: state.query.isEmpty) { _, isEmpty in
                    // Results start at their top, whatever the board's offset was: there, a short list's patches sit above the bar until
                    // it's scrolled. Clearing the words goes back to where the mode was.
                    if !isEmpty {
                        restore(0)
                    } else if let before = state.offsetsBeforeSearch {
                        state.offsets = before
                        restore(before[state.mode] ?? 0)
                    }
                }
                .onChange(of: state.topRequests) { restore(0) }
                .onChange(of: state.board) {
                    // Another board starts from its first patch.
                    state.offsets[.cards] = 0
                    restore(0)
                }
                .background { ModeSurface(mode: state.mode).ignoresSafeArea() }
                // Search in the title's row, so nothing moves the picker, and our own: the system's in this place has a close button that
                // does nothing with the keyboard up, and keeps the words with it down (DECISIONS.md). While it's open the navigation bar
                // gives way to it, in the bar with the picker, since a toolbar item won't hold a field that wide.
                .toolbarVisibility(state.isSearching ? .hidden : .automatic, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            state.offsetsBeforeSearch = state.offsets
                            state.searchWantsFocus = true
                            state.isSearching = true
                        } label: {
                            Label("Search", systemImage: "magnifyingglass")
                        }
                        .accessibilityFocused($magnifierHasFocus)
                        .accessibilityIdentifier("collection-search-open")
                    }
                }
                .scrollDismissesKeyboard(.immediately)
                #if DEBUG
                .task {
                    // Issue #119's screenshots: `-autoQuery <text>` searches once, for the no-match state.
                    if let text = UserDefaults.standard.string(forKey: "autoQuery") {
                        state.offsetsBeforeSearch = state.offsets
                        state.isSearching = true
                        state.query = text
                    }
                    // Issue #138's: `-autoBoard uncharted` opens the Uncharted board.
                    if UserDefaults.standard.string(forKey: "autoBoard") == "uncharted" { state.board = .uncharted }
                }
                #endif
            }
        }
        .navigationTitle("Collection")
        .toolbarTitleDisplayMode(.inlineLarge)
        .namesUnnamedSighting($naming) { namedHere = $0 }
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
            } else if !isCovered, !run.isReviewing, let acknowledgment = run.acknowledgment, let addition = acknowledgment.undo, addition == namedHere {
                // A photo named from "To name" (issue #188) is an add made here, so its acknowledgment and its Undo show here
                // too; an add made on the Listen tab keeps to that tab. Only the words: the count's tick and its haptic are
                // the Listen tab's toast's, which is still there.
                Toast(text: acknowledgment.text, undo: { run.undo(addition) })
                    .id(acknowledgment.id)
                    .padding(.bottom, 8)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .default, value: edits.pendingRemoval)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .default, value: run.acknowledgment)
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
            Text(Journal.summary(sightingCount: sightings.count, speciesCount: collection.speciesCount))
                .font(JournalFont.supporting)
                .foregroundStyle(Color.inkSecondary)
                .padding(.top, 6)
            if state.mode == .sightings {
                // A search is over birds' names, and these have none yet.
                if state.query.isEmpty, !captures.isEmpty {
                    ToNameGroup(unnamed: captures.map(UnnamedSighting.init)) { naming = $0 }
                }
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
            let shown = shownBoard(collection)
            // With more than one, the name is the menu pinned with the modes.
            if boards(collection).count == 1 {
                SectionTitle(boardTitle(shown), size: .lead, top: 12, onBoard: true)
                    .padding(.bottom, 6)
            }
            switch shown {
            case .set(let id):
                if let set = library.set(id: id) {
                    NavigationLink(value: Route.set(id: set.id)) {
                        SetThreadRow(progress: collection.progress(of: set.id), edition: set.edition.name)
                    }
                    .buttonStyle(.journalPress)
                    .accessibilityIdentifier("cards-set-progress")
                    PatchBoard(patches: collection.patches(in: set.id))
                }
            case .uncharted:
                Text("\(collection.unchartedPatches.count) outside every set")
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.ink)
                    .boardLabel()
                    .padding(.bottom, 4)
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

    /// The set's name is the menu for the others (issue #150, audit F9), in the bar with the modes. The menu carries the total across all
    /// of them: on the page, "5 patches" over "3 of 160 sewn" would seem to disagree. Being pinned it stops growing at the first
    /// accessibility size, or at the largest it would take a third of the page from the patches.
    private func setMenu(_ shown: BoardChoice, _ collection: CardCollection) -> some View {
        Menu {
            // A line of its own: a section's title doesn't show over a picker.
            Text(collection.summary)
            Divider()
            Picker("Set", selection: Binding(get: { shown }, set: { state.board = $0 })) {
                ForEach(boards(collection), id: \.self) { board in
                    Text(boardMenuTitle(board, collection)).tag(board)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(boardTitle(shown))
                    .font(JournalFont.section)
                    .lineLimit(2)
                Image(systemName: "chevron.down")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(Color.ink)
            .boardLabel()
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityLabel(boardTitle(shown))
        .accessibilityHint("Shows your other sets.")
        .accessibilityIdentifier("collection-board")
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
                SectionTitle(boardTitle(group.board), top: 10, onBoard: true)
                    .padding(.bottom, 10)
                // A new grid for new results: the old one keeps its range from the old offset, and at the largest text stayed blank.
                PatchBoard(patches: group.patches)
                    .id(group.patches.map(\.id))
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
        case .set(let id): library.set(id: id)?.name ?? id
        case .uncharted: CardPlacement.unchartedTitle
        }
    }

    /// Closes the search from whatever state it's in: the field, the keyboard and the words all go, and the board goes back to where it was.
    private func endSearch() {
        isClosingSearch = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            isClosingSearch = false
        }
        let before = state.offsetsBeforeSearch
        state.offsetsBeforeSearch = nil
        state.searchWantsFocus = false
        state.isSearching = false
        state.query = ""
        // The button VoiceOver was on has gone: its focus goes back to the one that opened the search.
        magnifierHasFocus = true
        if let before {
            state.offsets = before
            restore(before[state.mode] ?? 0)
        }
    }

    /// A different mode starts at its top; only returning from a page or search keeps the current mode's place.
    private func switchMode(to mode: Mode) {
        guard mode != state.mode else { return }
        // One transaction, with the mode written first. Written after the rest and alone in the animation, the mode's change found
        // the others waiting under a different transaction: SwiftUI drew those at once, from inside the mode's `willSet`, and at
        // times drew the mode's own change there too, while it still read the old mode. Nothing asked for it again, so the old
        // mode stayed on screen until something else redrew the page (seen after a patch's page closed, two times in three).
        withAnimation(modeFade) {
            state.mode = mode
            stopRestoring()
            position = ScrollPosition(edge: .top)
            offset = 0
            state.offsets[mode] = 0
            // Clearing a search after switching modes must not resurrect that mode's old position either.
            if state.offsetsBeforeSearch != nil { state.offsetsBeforeSearch?[mode] = 0 }
        }
    }

    /// The surface cross-fades from one mode to the next (issue #150, audit F10); under Reduce Motion, quickly.
    private var modeFade: Animation {
        #if DEBUG
        let seconds = UserDefaults.standard.double(forKey: "modeFadeSeconds")
        if seconds > 0 { return .linear(duration: seconds) }
        #endif
        return .easeInOut(duration: reduceMotion ? 0.12 : 0.25)
    }

    /// What's on the surface doesn't wait for the surface's fade, and the two modes are never both there: the old one has gone
    /// first, and the new one comes up after it.
    private var modeContentTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.animation(.easeOut(duration: reduceMotion ? 0.08 : 0.17).delay(0.08)),
            removal: .opacity.animation(.easeOut(duration: 0.05))
        )
    }

    /// Restores the current mode after a search, once its content has laid out. A single native scroll is
    /// clamped by the scroll view; never add an offset discrepancy to the target, since lazy content or a stale
    /// geometry report can make that correction overshoot the end. A newer request cancels the pending one.
    private func restore(_ saved: CGFloat) {
        restoring = true
        settling?.cancel()
        settling = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            position.scrollTo(y: saved)
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            restoring = false
            state.offsets[state.mode] = max(offset, 0)
        }
    }

    private func stopRestoring() {
        settling?.cancel()
        restoring = false
    }
}

/// The search field, in the title's row: the system's own search text field, so it looks and reads as one. It takes the keyboard, and
/// VoiceOver's focus, once, on opening: not each time it comes back on screen, over the results, from a patch's page or another tab.
/// The keyboard's Search key lowers it and keeps the results.
private struct CollectionSearchField: UIViewRepresentable {
    @Binding var query: String
    /// Set when the search opens, and cleared once this has answered it.
    @Binding var wantsFocus: Bool

    final class Field: UISearchTextField {
        var onWindow: (() -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { onWindow?() }
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        let query: Binding<String>

        init(query: Binding<String>) {
            self.query = query
        }

        @objc func changed(_ field: UITextField) {
            query.wrappedValue = field.text ?? ""
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            field.resignFirstResponder()
            return false
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(query: $query)
    }

    func makeUIView(context: Context) -> Field {
        let field = Field()
        field.placeholder = "Search birds"
        field.text = query
        field.returnKeyType = .search
        field.autocorrectionType = .no
        field.delegate = context.coordinator
        field.adjustsFontForContentSizeCategory = true
        // It's one line in the title's row, whatever the text size.
        field.maximumContentSizeCategory = .accessibilityMedium
        field.accessibilityIdentifier = "collection-search"
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed), for: .editingChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let wantsFocus = $wantsFocus
        field.onWindow = { [weak field] in
            Task { @MainActor in
                guard wantsFocus.wrappedValue, let field else { return }
                wantsFocus.wrappedValue = false
                field.becomeFirstResponder()
                UIAccessibility.post(notification: .layoutChanged, argument: field)
            }
        }
        return field
    }

    func updateUIView(_ field: Field, context: Context) {
        if field.text != query { field.text = query }
    }
}

/// What a mode sits on: felt under the patches, the page under the lists.
private struct ModeSurface: View {
    let mode: JournalView.Mode

    var body: some View {
        ZStack {
            if mode == .cards {
                BoardMaterial().transition(.opacity)
            } else {
                Color.paper.transition(.opacity)
            }
        }
    }
}

/// An empty collection (issues #119, #132, #138): the bare felt and "Your first patch is a bird away." It shows no patterns
/// and no blank, since a bird you haven't found has no patch (DECISIONS.md, issue #138). Start listening is the way to the
/// first patch, and the Atlas is where the birds still to find are.
private struct EmptyJournal: View {
    @Environment(\.openListen) private var openListen
    @Environment(\.openAtlas) private var openAtlas
    /// Photos waiting for a name (issue #188): with no sighting yet, naming one is the nearest way to the first patch.
    var unnamed: [UnnamedSighting] = []
    var name: (UnnamedSighting) -> Void = { _ in }

    var body: some View {
        ScrollView {
            if !unnamed.isEmpty {
                // On paper, as the Sightings list has them: the rows aren't drawn for the felt.
                ToNameGroup(unnamed: unnamed, top: 14, name: name)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
                    .background(Color.paper, in: RoundedRectangle(cornerRadius: JournalLayout.cornerRadius, style: .continuous))
                    .padding(.horizontal, JournalLayout.margin)
                    .padding(.top, 12)
            }
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
        .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: JournalLayout.cornerRadius, style: .continuous))
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

/// One sighting: your own photo when there is one, since that's evidence, else the Atlas's reference photo (the maintainer, issue
/// #150). Then the name, the time and the source, and whose photo it is, so a reference photo never reads as yours.
struct SightingRow: View {
    @Environment(PackLibrary.self) private var library
    @Environment(PlaceNames.self) private var places
    @Environment(\.dynamicTypeSize) private var typeSize
    let sighting: Sighting
    var showsDate = false

    var body: some View {
        let source = RowPictureSource.of(sighting: sighting, reference: library.thumbnailURL(scientificName: sighting.scientificName))
        AdaptiveRow(stacked: typeSize.stacksRows) {
            RowPicture(source: source, side: 84)
            VStack(alignment: .leading, spacing: 3) {
                Text(library.commonName(for: sighting))
                    .font(JournalFont.heading)
                    .foregroundStyle(Color.ink)
                Text("\(showsDate ? sighting.confirmedAt.formatted(date: .abbreviated, time: .shortened) : sighting.confirmedAt.formatted(date: .omitted, time: .shortened)), \(sighting.source == .glasses ? "added from glasses" : "added from iPhone")")
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.inkSecondary)
                if let caption = Self.caption(source) {
                    Text(caption)
                        .font(JournalFont.attribution)
                        .foregroundStyle(Color.inkSecondary)
                }
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

    /// Whose picture it is, so a reference photo never looks like your own.
    static func caption(_ source: RowPictureSource) -> String? {
        switch source {
        case .ownPhoto(_, let isGlassesFrame): isGlassesFrame ? "Your glasses snapshot" : "Your photo"
        case .silhouette: nil
        case .reference(let url): url == nil ? "No photo" : "Reference photo"
        }
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

/// Under a board's name: its thread and count, "3 of 160 sewn, Citrus edition", opening the set's page.
private struct SetThreadRow: View {
    let progress: SetProgress
    let edition: String

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                // Another set's thread is another thread: it doesn't sew from this one's count. The row says the count.
                ThreadProgress(progress)
                    .id(progress.setID)
                    .accessibilityHidden(true)
                Text("\(progress.sewnText), \(edition)")
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.ink)
            }
            Image(systemName: "chevron.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.ink)
        }
        .boardLabel(horizontal: 10, vertical: 6)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(progress.name), \(progress.sewnText), \(edition)")
        .accessibilityHint("Opens the set.")
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
                ThreadProgress(progress)
                    .accessibilityHidden(true)
            }
            Image(systemName: "chevron.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(detailInk)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel([progress.name, progress.sewnText, detail].compactMap { $0 }.joined(separator: ", "))
    }
}

/// The Species list: one row per bird added, with how many sightings and when last, each opening its
/// patches (issue #134). Its picture is always the Atlas's reference photo (the maintainer, issue #150). Lazy, so a long list asks
/// for only the photos on screen.
private struct SpeciesRows: View {
    @Environment(PackLibrary.self) private var library
    @Environment(\.dynamicTypeSize) private var typeSize
    let entries: [Journal.SpeciesEntry]

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(entries) { entry in
                let reference = library.species(scientificName: entry.scientificName)
                NavigationLink(value: Route.speciesPatches(scientificName: entry.scientificName, commonName: reference?.species.commonName ?? entry.commonName)) {
                    AdaptiveRow(stacked: typeSize.stacksRows) {
                        RowPicture(source: .reference(library.thumbnailURL(scientificName: entry.scientificName)))
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
