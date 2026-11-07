import Album
import Identification
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

        /// Something other than the friend's phone names it. Anything else may be anyone's words, so it goes nowhere that would
        /// print them as a bird's name.
        var isNamed = true

        /// A patch the friend's side shows goes to the bird in the Atlas, the way to go and find it. Only yours opens your own.
        var route: Route? {
            if theirs == nil, let myPatch { return .patch(myPatch, from: .compare) }
            return isNamed ? .species(scientificName: scientificName, commonName: commonName) : nil
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
    ///   - names: what the packs and BirdNET call each bird. These win over the words on the birder's own sightings. The friend's
    ///     phone's words are never used: nothing checks them, and every bird a real phone can find is in BirdNET's list.
    ///   - myPatches: the birder's patches, for what shows under "Only you".
    init(mine: [(speciesID: String, method: SightingMethod)], theirs: [FriendBirds.Species], names: BirdNames = BirdNames(), myPatches: [CardCollection.Patch] = []) {
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
            let common = names[name] ?? myBest[name]?.common
            rows.append(Row(
                scientificName: name,
                commonName: common ?? BirdNames.unnamed,
                mine: myBest[name]?.method,
                theirs: their?.method,
                edition: their.map { $0.editions.first } ?? mine?.placement.setID,
                myPatch: mine?.id,
                isNamed: common != nil
            ))
        }
        // What nothing names goes last, so it can't lead a board.
        rows.sort { ($0.isNamed ? 0 : 1, $0.commonName, $0.scientificName) < ($1.isNamed ? 0 : 1, $1.commonName, $1.scientificName) }
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

    /// What a row's method says under its patch: "Heard by Maya", "Seen by you", "Seen by both", "You heard, Maya saw". VoiceOver
    /// has the longer sentence.
    static func caption(_ row: Row, friend: String) -> String {
        switch (row.mine, row.theirs) {
        case (let mine?, let theirs?) where mine == theirs: "\(mine.title) by both"
        case (let mine?, let theirs?): "You \(mine.verb), \(friend) \(theirs.verb)"
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

private extension SightingMethod {
    /// "heard" or "saw".
    var verb: String { self == .seen ? "saw" : "heard" }
}

/// You and a friend as boards of patches, as the reference draws it: theirs you don't have yet, then what you both have, then only
/// yours, then the tally. On felt: these are objects. A friend's illustration may use another available edition;
/// the viewer's own patches remain strictly in their original editions.
struct CompareBirdsView: View {
    @Environment(CircleStore.self) private var circles
    @Environment(PackLibrary.self) private var library
    @Environment(CollectionStore.self) private var collectionStore
    @Query private var sightings: [Sighting]
    let friendID: String
    let friendName: String
    @State private var error: String?
    /// Read once as the screen opens, not again on the way back from a bird it opened: pull to refresh reads again. Except with nothing
    /// to draw: a Guild the two shared has gone, say, while this stayed open behind another tab.
    @State private var hasRead = false

    /// What was last read of the friend, drawn at once and refreshed in place.
    private var friend: FriendBirds? { circles.friendBirds[friendID] }

    private var firstName: String { CircleMember.firstName(of: friendName) }

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
        .task(id: friend == nil) {
            guard !hasRead || friend == nil else { return }
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
                if comparison.onlyTheirs.isEmpty, comparison.onlyMine.isEmpty, comparison.both.isEmpty {
                    StateNotice("Neither of you has found a bird yet.", messageInk: .ink)
                        .boardLabel()
                }
                board(comparison.onlyTheirs, title: BirdComparison.leadTitle(friend: firstName), isLead: true)
                board(comparison.both, title: "You both have", scrollID: "compare-both")
                board(comparison.onlyMine, title: "Only you")
                Text(comparison.tally(friend: firstName))
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .boardLabel()
                    .padding(.top, JournalLayout.sectionGap)
                    .accessibilityIdentifier("compareTally")
                Text("\(firstName)'s side is what they shared to Guilds you're both in. Yours is everything on this iPhone.")
                    .font(JournalFont.attribution)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .boardLabel()
                    .padding(.top, 6)
            }
        } else if let error {
            GuildsUnreachable(message: error) { Task { await load() } }
        } else {
            VStack(alignment: .leading, spacing: 12) { GuildPlaceholder(rows: 4) }
        }
    }

    @ViewBuilder
    private func board(_ rows: [BirdComparison.Row], title: String, isLead: Bool = false, scrollID: String? = nil) -> some View {
        if !rows.isEmpty {
            // Every item in a lazy stack needs its own identity: two sharing nil lost a heading.
            SectionTitle(title, size: isLead ? .lead : .section, top: isLead ? 8 : 26, onBoard: true)
                .id(scrollID ?? title)
            BoardTiles(tiles: rows.map(tile), side: isLead ? 97 : 79, lineFont: isLead ? PatchFont.boardLine : PatchFont.tileLine)
                .padding(.top, 10)
        }
    }

    private func tile(_ row: BirdComparison.Row) -> BoardTile {
        // "Only you" opens your actual patch: borrowing another edition here would change the picture on a tap.
        let artwork = row.theirs == nil ? nil : library.guildPatchArtwork(scientificName: row.scientificName, setID: row.edition)
        return BoardTile(
            id: row.scientificName, scientificName: row.scientificName, setID: artwork?.setID ?? row.edition, name: row.commonName,
            caption: [BirdComparison.caption(row, friend: firstName), artwork?.note].compactMap { $0 }.joined(separator: "\n"),
            spoken: ["\(row.commonName). You: \(BirdComparison.word(row.mine)). \(firstName): \(BirdComparison.word(row.theirs)).", artwork?.note].compactMap { $0 }.joined(separator: " "),
            hint: row.route == nil ? nil : row.theirs == nil && row.myPatch != nil ? "Opens your patch." : "Opens this bird in the Atlas.",
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

/// One patch on a Guild's board: a bird in an edition that may be anyone's.
struct BoardTile: Identifiable {
    let id: String
    let scientificName: String
    /// The illustration's edition, resolved before making the tile. Personal patches keep their own edition.
    let setID: String?
    /// Under the patch, and on the blank's tag.
    let name: String
    let caption: String?
    let spoken: String
    let hint: String?
    /// Nil where there's nowhere to go.
    let route: Route?
    let identifier: String
    /// The tile a patch's page grows out of, if that's where it goes.
    var lift: PatchLiftID? = nil
}

/// Patches in threes on felt, with their words under them, as the reference draws them. It builds only the rows near the screen,
/// however long the board.
struct BoardTiles: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(PackLibrary.self) private var library
    let tiles: [BoardTile]
    /// How wide a patch may be.
    let side: CGFloat
    var lineFont = PatchFont.tileLine

    var body: some View {
        LazyVGrid(columns: PatchBoardLayout.grid(for: typeSize, spacing: 8), alignment: .leading, spacing: 18) {
            ForEach(tiles) { tile in
                let picture = PatchTile(
                    state: library.patchArtState(scientificName: tile.scientificName, setID: tile.setID), edition: PatchEdition.of(setID: tile.setID),
                    tag: tile.name, name: tile.name, line: tile.caption, spoken: tile.spoken, lift: tile.lift, side: side, nameFont: PatchFont.boardName, lineFont: lineFont
                )
                if let route = tile.route {
                    NavigationLink(value: route) { picture }
                        .buttonStyle(.patchLift)
                        .accessibilityHint(tile.hint ?? "")
                        .accessibilityIdentifier(tile.identifier)
                } else {
                    picture
                        .accessibilityIdentifier(tile.identifier)
                }
            }
        }
    }
}

extension PackLibrary {
    /// "Citrus edition", when this phone knows the set.
    func editionLabel(setID: String?) -> String? {
        cardSets.first { $0.id == setID }?.edition
    }

    /// What the packs and sets on this phone call each bird, then BirdNET. The server's names are the finder's phone's word.
    var birdNames: BirdNames {
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
        return BirdNames(packs: names)
    }
}

/// What a bird is called, from what ships with the app and never from the server: the packs, or BirdNET's own list, which holds every
/// bird a phone can find. Nil is a name nobody but the sender vouches for: a hand-built client, or a newer model's bird.
struct BirdNames: Equatable {
    /// A bird with no name to trust.
    static let unnamed = "A bird this iPhone can't name"

    /// BirdNET's list. It's about 11,000 lines, so it's read once, the first time a bird isn't in a pack.
    private nonisolated static let birdNET: [String: String] = {
        let species = (try? ONNXBirdModel.bundledLabels()) ?? []
        return Dictionary(species.map { ($0.scientificName, $0.commonName) }, uniquingKeysWith: { first, _ in first })
    }()

    var packs: [String: String] = [:]

    subscript(scientificName: String) -> String? {
        packs[scientificName] ?? Self.birdNET[scientificName]
    }
}
