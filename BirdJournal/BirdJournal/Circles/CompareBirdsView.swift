import Album
import Pack
import SwiftData
import SwiftUI

/// Compare birds (issues #64, #150): the birder and a friend, by species. The friend's side is the server's (their finds in the
/// circles the two share, Seen beating Heard, and the editions they found each in); the birder's comes from the collection on this
/// phone, so private sightings count too and nothing of it is sent. Pure, for the tests.
struct BirdComparison: Equatable {
    struct Row: Equatable, Identifiable {
        var scientificName: String
        var commonName: String
        /// The birder's best, nil when not yet found.
        var mine: SightingMethod?
        var theirs: SightingMethod?
        /// The patch shown: the edition the friend first found it in, wherever the friend has it, else the birder's own. Nil is
        /// the blank with its tag: the friend's finds name no set, or the birder's patch is Uncharted.
        var edition: String?
        /// The birder's own patch of it, the earliest sewn, if the collection was given.
        var myPatch: CardCollection.Patch.Key?

        var id: String { scientificName }

        /// A patch the friend's side shows goes to the bird in the Atlas, the way to go and find it. Only yours opens your own.
        var route: Route {
            if theirs == nil, let myPatch { return .patch(myPatch, from: .compare) }
            return .species(scientificName: scientificName, commonName: commonName)
        }
    }

    /// What the friend has found and the birder hasn't: the next walk.
    var onlyTheirs: [Row]
    var onlyMine: [Row]
    var both: [Row]

    var myCount: Int { onlyMine.count + both.count }
    var theirCount: Int { onlyTheirs.count + both.count }

    /// - Parameters:
    ///   - mine: every sighting's BirdNET label and method; species meet by scientific name.
    ///   - names: what the packs call each bird, by scientific name. These win over the words on the birder's own sightings, and
    ///     those over the friend's phone's, which nothing checks.
    ///   - myPatches: the birder's patches, for what shows under "Only you".
    init(mine: [(speciesID: String, method: SightingMethod)], theirs: [FriendBirds.Species], names: [String: String] = [:], myPatches: [CardCollection.Patch] = []) {
        var myBest: [String: (common: String, method: SightingMethod)] = [:]
        for (label, method) in mine {
            let scientific = Sighting.scientificName(ofLabel: label)
            if myBest[scientific]?.method != .seen {
                myBest[scientific] = (Self.commonName(ofLabel: label), method)
            }
        }
        var theirBest: [String: FriendBirds.Species] = [:]
        for species in theirs where theirBest[species.scientificName]?.method != .seen {
            theirBest[species.scientificName] = species
        }
        var firstPatch: [String: CardCollection.Patch] = [:]
        for patch in myPatches {
            if let first = firstPatch[patch.scientificName], first.sewn.confirmedAt <= patch.sewn.confirmedAt { continue }
            firstPatch[patch.scientificName] = patch
        }
        var rows: [Row] = []
        for name in Set(myBest.keys).union(theirBest.keys) {
            let their = theirBest[name]
            let mine = firstPatch[name]
            rows.append(Row(
                scientificName: name,
                commonName: names[name] ?? myBest[name]?.common ?? their?.commonName ?? name,
                mine: myBest[name]?.method,
                theirs: their?.method,
                edition: their.map { $0.editions.first } ?? mine?.placement.setID,
                myPatch: mine?.id
            ))
        }
        rows.sort { ($0.commonName, $0.scientificName) < ($1.commonName, $1.scientificName) }
        onlyTheirs = rows.filter { $0.mine == nil }
        onlyMine = rows.filter { $0.theirs == nil }
        both = rows.filter { $0.mine != nil && $0.theirs != nil }
    }

    static func commonName(ofLabel label: String) -> String {
        guard let separator = label.firstIndex(of: "_") else { return label }
        return String(label[label.index(after: separator)...])
    }

    /// "Heard", "Seen" or "Not yet".
    static func word(_ method: SightingMethod?) -> String { method?.title ?? "Not yet" }

    /// "Maya has these. Go find them."
    static func leadTitle(friend: String) -> String { "\(friend) has these. Go find them." }

    /// What a row's method says under its patch: "Heard by Maya", "Seen by you", "Seen by you both", "Heard by you, seen by Maya".
    static func caption(_ row: Row, friend: String) -> String {
        switch (row.mine, row.theirs) {
        case (let mine?, let theirs?) where mine == theirs: "\(mine.title) by you both"
        case (let mine?, let theirs?): "\(mine.title) by you, \(theirs.title.lowercased()) by \(friend)"
        case (let mine?, nil): "\(mine.title) by you"
        case (nil, let theirs?): "\(theirs.title) by \(friend)"
        case (nil, nil): ""
        }
    }

    /// "You have 5, Maya has 5, and you both have 2."
    func tally(friend: String) -> String {
        "You have \(myCount), \(friend) has \(theirCount), and you both have \(both.count)."
    }
}

/// You and a friend as boards of patches, as the reference draws it: theirs you don't have yet, then what you both have, then only
/// yours. On felt: these are objects. Patches in threes, a friend's in the edition they first found it, and the blank with its tag
/// when the server names no edition, or one this phone can't paint.
struct CompareBirdsView: View {
    @Environment(CircleStore.self) private var circles
    @Environment(PackLibrary.self) private var library
    @Environment(CollectionStore.self) private var collectionStore
    @Query private var sightings: [Sighting]
    let friendID: String
    let friendName: String
    @State private var error: String?
    /// Read once as the screen opens, not again on the way back from a bird it opened: pull to refresh reads again.
    @State private var hasRead = false

    /// What was last read of the friend, drawn at once and refreshed in place.
    private var friend: FriendBirds? { circles.friendBirds[friendID] }

    private var firstName: String { friendName.split(separator: " ").first.map(String.init) ?? friendName }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, JournalLayout.margin)
                    .padding(.top, 4)
                    .padding(.bottom, JournalLayout.sectionGap)
            }
            #if DEBUG
            .debugScroll(proxy, to: "compare-both", when: friend != nil)
            #endif
        }
        .patchSheetBackground()
        .holdsPatchLight()
        .navigationTitle("You and \(firstName)")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !hasRead else { return }
            hasRead = true
            await load()
        }
        .refreshable { await load() }
    }

    @ViewBuilder private var content: some View {
        if let friend {
            let comparison = BirdComparison(
                mine: sightings.map { ($0.speciesID, $0.method) }, theirs: friend.species,
                names: library.birdNames, myPatches: collectionStore.collection.patches
            )
            LazyVStack(alignment: .leading, spacing: 0) {
                Text(comparison.tally(friend: firstName))
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .boardLabel()
                    .accessibilityIdentifier("compareTally")
                if comparison.onlyTheirs.isEmpty, comparison.onlyMine.isEmpty, comparison.both.isEmpty {
                    StateNotice("Neither of you has found a bird yet.", messageInk: .ink)
                        .boardLabel()
                }
                board(comparison.onlyTheirs, title: BirdComparison.leadTitle(friend: firstName), isLead: true)
                board(comparison.both, title: "You both have", id: "compare-both")
                board(comparison.onlyMine, title: "Only you")
                Text("\(firstName)'s side is what they shared to Guilds you're both in. Yours is everything on this iPhone.")
                    .font(JournalFont.attribution)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .boardLabel()
                    .padding(.top, JournalLayout.sectionGap)
            }
        } else if let error {
            GuildsUnreachable(message: error) { Task { await load() } }
        } else {
            VStack(alignment: .leading, spacing: 12) { GuildPlaceholder(rows: 4) }
        }
    }

    @ViewBuilder
    private func board(_ rows: [BirdComparison.Row], title: String, isLead: Bool = false, id: String? = nil) -> some View {
        if !rows.isEmpty {
            SectionTitle(title, size: isLead ? .lead : .section, top: isLead ? 18 : 26, onBoard: true)
                .id(id)
            PatchTiles(tiles: rows.map(tile), side: isLead ? 97 : 79)
                .padding(.top, 10)
        }
    }

    private func tile(_ row: BirdComparison.Row) -> PatchTile {
        PatchTile(
            id: row.scientificName, scientificName: row.scientificName, setID: row.edition, name: row.commonName,
            caption: BirdComparison.caption(row, friend: firstName),
            spoken: "\(row.commonName). You: \(BirdComparison.word(row.mine)). \(firstName): \(BirdComparison.word(row.theirs)).",
            hint: row.theirs == nil && row.myPatch != nil ? "Opens your patch." : "Opens this bird in the Atlas.",
            route: row.route, identifier: "compare-\(row.scientificName)",
            lift: row.theirs == nil ? row.myPatch.map { PatchLiftID(key: $0, surface: .compare) } : nil
        )
    }

    private func load() async {
        do {
            try await circles.compare(friendID: friendID)
            error = nil
        } catch {
            self.error = CircleStore.message(for: error, doing: "compare your birds")
        }
    }
}

/// One patch on a board, as the reference draws them: the patch, its name, and a line under it, in an edition that may be anyone's.
struct PatchTile: Identifiable, Equatable {
    let id: String
    let scientificName: String
    /// The patch's edition. Nil, or one the phone has no painting in, is the blank; it's never drawn with another edition's.
    let setID: String?
    /// Under the patch and on the blank's tag. Nil for a bird nothing trustworthy names, which is a bare blank.
    let name: String?
    let caption: String?
    let spoken: String
    let hint: String?
    /// Nil where there's nowhere to go.
    let route: Route?
    let identifier: String
    /// The tile a patch's page grows out of, if that's where it goes.
    var lift: PatchLiftID? = nil
}

/// Patches in threes, on felt, with what's on them under them. It builds only the rows near the screen, however long the board.
struct PatchTiles: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let tiles: [PatchTile]
    /// The patch's side at the default text size.
    let side: CGFloat

    private var columns: Int {
        if typeSize >= .accessibility3 { return 1 }
        return typeSize.isAccessibilitySize ? 2 : 3
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: columns), alignment: .leading, spacing: 18) {
            ForEach(tiles) { PatchTileView(tile: $0, side: side) }
        }
    }
}

private struct PatchTileView: View {
    let tile: PatchTile
    /// The patch's side at the default text size.
    let side: CGFloat
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        if let route = tile.route {
            NavigationLink(value: route) { label }
                .buttonStyle(.patchLift)
                .accessibilityHint(tile.hint ?? "")
                .accessibilityIdentifier(tile.identifier)
        } else {
            label
                .accessibilityIdentifier(tile.identifier)
        }
    }

    private var label: some View {
        VStack(spacing: 4) {
            EditionPatch(scientificName: tile.scientificName, setID: tile.setID, tag: tile.name)
                .frame(maxWidth: min(side * scale, 170))
                .patchLiftSource(tile.lift)
            if let name = tile.name {
                Text(name)
                    .font(JournalFont.rowTitle)
                    .foregroundStyle(Color.ink)
                    .boardLabel()
            }
            if let caption = tile.caption {
                Text(caption)
                    .font(JournalFont.attribution)
                    .foregroundStyle(Color.ink)
                    .boardLabel()
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        // The art takes no touches of its own (`PatchView`): the whole tile is what opens.
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tile.spoken)
    }

}

/// A patch in whichever edition it was found, which may not be one of yours: `PatchView`, on its two-at-a-time decode queue, a plain
/// bitmap under the shader. Without that edition's painting (no pack, no painting of the bird, or a word the server passed on that
/// names no set) it's the plain blank with the bird's name on its tag, and never another edition's patch.
struct EditionPatch: View {
    @Environment(PackLibrary.self) private var library
    let scientificName: String
    let setID: String?
    let tag: String?

    var body: some View {
        let edition = PatchEdition.of(setID: setID)
        let state = library.patchArtState(scientificName: scientificName, setID: setID)
        if let tag {
            PatchView(state: state, edition: edition, tag: tag)
        } else {
            PatchView(art: state.art, edition: edition)
        }
    }
}

extension PackLibrary {
    /// What the packs and sets on this phone call each bird, by scientific name. The server's names are the finder's phone's word.
    var birdNames: [String: String] {
        var names: [String: String] = [:]
        for set in sets {
            for species in set.species where names[species.scientificName] == nil {
                names[species.scientificName] = species.commonName
            }
        }
        for pack in packs {
            for species in pack.species where names[species.scientificName] == nil {
                names[species.scientificName] = species.commonName
            }
        }
        return names
    }
}
