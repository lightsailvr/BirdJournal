import Album
import Pack
import SwiftUI

/// A run of finds on the felt (issue #62; guide 2.0 page 8; issue #150, G4): friends' sightings, newest first. A new patch leads
/// with the finder's patch at about 100 pt, with who sewed it, the bird, how and where they met it, when, and its marks. A repeat
/// sighting is a quieter "saw a House Finch again" line, and a member's consecutive repeats within a day gather into one line that
/// expands in place. Anything marked stands on its own. Under each find, its reactions (issue #64): a friend's find takes a tap
/// on each, the birder's own shows what friends gave. Each find opens its page. No comments.
struct FindsColumn: View {
    @Environment(CircleStore.self) private var circles
    let entries: [FindEntry]
    /// Where the finds are: their pages' way back.
    let surface: FindLiftSurface
    /// Each row says which Guilds it's in, on the feed that runs across them.
    var namesGuilds = false
    /// Report a friend's find, and block its owner (issue #71): whoever holds this presents the sheet and the dialog.
    var onReport: (FindEntry) -> Void = { _ in }
    var onBlock: (FeedItem.Owner) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    /// The finds whose repeat line is open. By find, so a new repeat at the head of a line leaves it open.
    @State private var expanded: Set<String> = []
    /// The latest reaction that didn't land: said at its find, where the birder's thumb is.
    @State private var reactionFailure: ReactionFailure?

    private struct ReactionFailure {
        let itemID: String
        let message: String
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(FindFeedRow.rows(of: entries)) { row in
                VStack(alignment: .leading, spacing: 0) {
                    switch row {
                    case .find(let entry):
                        find(entry)
                    case .repeats(let line):
                        repeats(line)
                    }
                    FeedRule()
                }
            }
        }
        // What a page's `.scrollPosition` holds on to, so a find landing above doesn't move a row under a thumb.
        .scrollTargetLayout()
        #if DEBUG
        // `-autoOpenRepeats YES`, for the screenshots: every line of repeats open.
        .onChange(of: entries.count, initial: true) {
            if UserDefaults.standard.bool(forKey: "autoOpenRepeats") { expanded.formUnion(entries.map(\.id)) }
        }
        #endif
    }

    private func find(_ entry: FindEntry) -> some View {
        FindCard(
            entry: entry, surface: surface, guilds: guildNames(entry),
            reactionError: reactionFailure?.itemID == entry.id ? reactionFailure?.message : nil,
            react: { kind, given in react(kind, given: given, to: entry.item) },
            onReport: { onReport(entry) },
            onBlock: { onBlock(entry.item.owner) }
        )
    }

    @ViewBuilder private func repeats(_ line: [FindEntry]) -> some View {
        let isOpen = line.contains { expanded.contains($0.id) }
        VStack(alignment: .leading, spacing: 0) {
            RepeatLine(entries: line, guilds: namesGuilds ? guildNames(in: line) : nil, isOpen: isOpen) {
                withAnimation(PatchMotion.reduces(system: systemReduceMotion) ? nil : .easeInOut(duration: 0.2)) {
                    if isOpen {
                        expanded.subtract(line.map(\.id))
                    } else {
                        expanded.formUnion(line.map(\.id))
                    }
                }
            }
            if isOpen {
                ForEach(line) { entry in
                    find(entry)
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Color.ink.opacity(0.22)).frame(width: 2).padding(.vertical, 6)
                        }
                }
            }
        }
    }

    private func guildNames(_ entry: FindEntry) -> [String]? {
        namesGuilds ? guildNames(in: [entry]) : nil
    }

    /// The Guilds these finds are in, in the order they're listed.
    private func guildNames(in entries: [FindEntry]) -> [String] {
        let ids = Set(entries.flatMap(\.circleIDs))
        return circles.circles.filter { ids.contains($0.id) }.map(\.name)
    }

    private func react(_ kind: ReactionKind, given: Bool, to item: FeedItem) {
        Task {
            do {
                try await circles.react(kind, given: given, to: item)
                reactionFailure = nil
            } catch {
                reactionFailure = ReactionFailure(itemID: item.id, message: CircleStore.message(for: error, doing: "send your reaction"))
            }
        }
    }
}

/// The fine rule between finds.
private struct FeedRule: View {
    var body: some View {
        Rectangle()
            .fill(Color.ink.opacity(0.16))
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

/// A member's gathered repeats (issue #150, G4): one line saying how many and which birds, opening in place.
private struct RepeatLine: View {
    let entries: [FindEntry]
    let guilds: [String]?
    let isOpen: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(FindRow.gatheredLine(entries.map(\.item)))
                        .font(JournalFont.supporting.weight(.medium))
                    Text(FindRow.birds(entries.map(\.item)))
                        .font(JournalFont.attribution)
                    if let guilds {
                        Text(FindRow.inGuilds(guilds))
                            .font(JournalFont.attribution)
                    }
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .boardLabel()
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Color.ink)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.journalPress)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(FindRow.spokenLine(entries.map(\.item), guilds: guilds))
        .accessibilityValue(isOpen ? "Open" : "Closed")
        .accessibilityHint(isOpen ? "Gathers them into one line." : "Lists each one, to open or react to.")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("repeats-\(entries.first?.item.sightingID ?? "")")
    }
}

/// One find with its reactions and its menu. Everything but those opens the find's page.
private struct FindCard: View {
    let entry: FindEntry
    let surface: FindLiftSurface
    let guilds: [String]?
    var reactionError: String?
    let react: (ReactionKind, Bool) -> Void
    let onReport: () -> Void
    let onBlock: () -> Void

    private var item: FeedItem { entry.item }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink(value: Route.find(FindRoute(itemID: item.id, surface: surface, liftsFromPatch: FindRow.isLed(item)))) {
                FindRow(item: item, guilds: guilds, lift: FindLiftID(itemID: item.id, surface: surface))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.patchLift)
            .accessibilityLabel(FindRow.spoken(item, guilds: guilds))
            .accessibilityHint("Opens the find.")
            .accessibilityIdentifier("find-\(item.sightingID)")
            .contextMenu {
                if !item.isMine { FindMenuItems(item: item, onReport: onReport, onBlock: onBlock) }
            }
            ReactionBar(item: item, react: react)
            if let reactionError {
                InlineError(reactionError, afterAction: true)
                    .boardLabel()
                    .accessibilityIdentifier("reaction-error-\(item.sightingID)")
            }
        }
        // The whole row's width, so the menu sits in one place on every row.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 16)
        .overlay(alignment: .topTrailing) {
            if !item.isMine {
                // Report and Block in plain sight (issue #150); touch and hold still works.
                Menu {
                    FindMenuItems(item: item, onReport: onReport, onBlock: onBlock)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.ink)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .accessibilityLabel("More about \(item.owner.name)'s \(item.commonName)")
                // Not "find-…": that's how the tests pick out the find rows themselves.
                .accessibilityIdentifier("menu-find-\(item.sightingID)")
                .offset(x: 10, y: 4)
            }
        }
    }
}

/// Report and Block, in a find's menus.
struct FindMenuItems: View {
    let item: FeedItem
    let onReport: () -> Void
    let onBlock: () -> Void

    var body: some View {
        Button("Report this find…", systemImage: "exclamationmark.bubble", action: onReport)
        Button("Block \(item.owner.name)…", systemImage: "hand.raised", role: .destructive, action: onBlock)
    }
}

/// A find's reactions (issue #150, G9): on a friend's find, the three fixed ones to tap (again to take back), each with its count,
/// in three equal pills a thumb can hit. A tap pops, ticks the count and gives a light haptic, and the store's optimistic update
/// shows it at once. On the birder's own, only what friends gave, not tappable. No comments.
struct ReactionBar: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let item: FeedItem
    let react: (ReactionKind, Bool) -> Void
    /// Taps on the reactions: the haptic's trigger. A reaction taken back says so too.
    @State private var reacted = 0

    var body: some View {
        if item.isMine {
            let given = item.reactions.filter { $0.count > 0 }
            if !given.isEmpty {
                Text(Self.summary(given))
                    .font(JournalFont.attribution)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .boardLabel()
                    .accessibilityIdentifier("reactions-\(item.sightingID)")
            }
        } else {
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 7)) : AnyLayout(HStackLayout(alignment: .top, spacing: 7))
            layout {
                ForEach(ReactionKind.allCases) { kind in
                    ReactionPill(kind: kind, count: item.reaction(kind), sightingID: item.sightingID) {
                        reacted += 1
                        react(kind, !item.reaction(kind).mine)
                    }
                }
            }
            // As tall as the one with the most lines, so the three stay equal.
            .fixedSize(horizontal: false, vertical: true)
            .haptic(.reaction, trigger: reacted)
        }
    }

    /// "Lovely find 2, Let's go together 1".
    static func summary(_ counts: [ReactionCount]) -> String {
        counts.map { "\($0.kind.title) \($0.count)" }.joined(separator: ", ")
    }
}

/// One reaction: a pill 44 pt tall, filled with the tint once it's yours. Its name wraps within its third of the row, and its count
/// ticks over. Its pop is the tap's and nothing else's, so nothing moves when a count changes by itself.
private struct ReactionPill: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var typeSize
    let kind: ReactionKind
    let count: ReactionCount
    let sightingID: String
    let tap: () -> Void
    @State private var pops = 0

    private var isStill: Bool { PatchMotion.reduces(system: systemReduceMotion) }

    var body: some View {
        Button {
            pops += 1
            tap()
        } label: {
            label
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(count.mine ? AnyShapeStyle(Color.mossText) : AnyShapeStyle(Color.ink))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, minHeight: 44, maxHeight: .infinity)
                .background { pill }
                .contentShape(.rect)
                // The store's update comes a moment after the tap, in its own task, so the tick is tied to the count.
                .animation(isStill ? nil : .spring(response: 0.25, dampingFraction: 0.7), value: count)
                .keyframeAnimator(initialValue: 1.0, trigger: pops) { content, scale in
                    content.scaleEffect(isStill ? 1 : scale)
                } keyframes: { _ in
                    KeyframeTrack {
                        SpringKeyframe(1.12, duration: 0.11, spring: .snappy)
                        SpringKeyframe(1, duration: 0.2, spring: .bouncy)
                    }
                }
        }
        .buttonStyle(.journalPress)
        .accessibilityLabel(kind.title)
        .accessibilityValue(count.count == 1 ? "1 reaction" : "\(count.count) reactions")
        .accessibilityAddTraits(count.mine ? .isSelected : [])
        .accessibilityIdentifier("react-\(kind.rawValue)-\(sightingID)")
    }

    private var label: some View {
        // A count stays with its last word when the name wraps.
        Text(count.count > 0 ? "\(kind.title)\u{00A0}\(count.count)" : kind.title)
            .monospacedDigit()
            .contentTransition(.numericText(value: Double(count.count)))
    }

    /// A capsule, or a rounded rectangle at accessibility sizes, where its words may wrap (issue #150).
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: JournalLayout.outlineRadius(typeSize), style: .continuous)
    }

    @ViewBuilder private var pill: some View {
        if count.mine {
            shape.fill(.tint)
        } else {
            // Stronger, and ringed, under Increase Contrast.
            shape.fill(Color.ink.opacity(contrast == .increased ? 0.22 : 0.1))
                .overlay {
                    if contrast == .increased { shape.strokeBorder(Color.ink, lineWidth: 1) }
                }
        }
    }
}

/// One find (guide 2.0 page 8). A new patch, or a card shared by hand, is led by the patch: who sewed it, then the bird, how and
/// where they met it, when, and its marks. A repeat sighting is one quiet line with its marks. VoiceOver reads the bird first,
/// either way.
struct FindRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let item: FeedItem
    /// The Guilds it's in, on the feed that runs across them.
    var guilds: [String]? = nil
    var lift: FindLiftID? = nil

    var body: some View {
        Group {
            if Self.isLed(item) {
                led
            } else {
                seenAgain
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(item, guilds: guilds))
    }

    /// The first line stays clear of the menu at the row's corner.
    private var clearOfMenu: CGFloat { item.isMine ? 0 : 30 }

    private var led: some View {
        VStack(alignment: .leading, spacing: 10) {
            AdaptiveRow(stacked: typeSize.isAccessibilitySize, spacing: 16) {
                FindPatch(item: item, side: 104)
                    .findLiftSource(lift)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.headline(item))
                        .font(JournalFont.supporting)
                        .padding(.trailing, clearOfMenu)
                    Text(item.commonName).font(JournalFont.section)
                    Text(Self.howAndWhere(item)).font(JournalFont.supporting)
                    if let guilds {
                        Text(Self.inGuilds(guilds)).font(JournalFont.attribution)
                    }
                    marks.padding(.top, 6)
                }
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .boardLabel()
            }
            if let card = item.card {
                SharedCardExtras(card: card)
            }
        }
    }

    /// "Maya Ortiz heard a Black Phoebe again in Pasadena, 2 hours ago".
    private var seenAgain: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Self.seenAgainLine(item))
                .font(JournalFont.supporting)
                .padding(.trailing, clearOfMenu)
            if let guilds {
                Text(Self.inGuilds(guilds)).font(JournalFont.attribution)
            }
            marks.padding(.top, 2)
        }
        .foregroundStyle(Color.ink)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .boardLabel()
    }

    @ViewBuilder private var marks: some View {
        let marks = Self.marks(item)
        if !marks.isEmpty {
            FlowMarks(marks: marks)
        }
    }

    /// Whether the patch leads the row: a new patch, or a card the finder chose to share. Anything else is a repeat sighting.
    static func isLed(_ item: FeedItem) -> Bool {
        item.newPatch || item.card != nil
    }

    /// "Black Phoebe. Heard by Maya Ortiz. Pasadena, 2 hours ago. New patch. First for the Guild.", then a shared card's
    /// caption and note, and on the feed across Guilds where it is; a repeat says "Heard again by Maya Ortiz".
    static func spoken(_ item: FeedItem, guilds: [String]? = nil) -> String {
        var parts = [item.commonName, isLed(item) ? byline(item) : againByline(item), whereAndWhen(item)]
        if item.newPatch { parts.append(newPatch) }
        parts += marks(item)
        if let caption = item.card?.caption { parts.append(caption) }
        if let note = item.card?.note { parts.append("Note: \(note)") }
        if item.card?.photo?.url != nil { parts.append("With their photo") }
        if let guilds, !guilds.isEmpty { parts.append(inGuilds(guilds)) }
        return parts.joined(separator: ". ")
    }

    /// "In Sunday Group and Family".
    static func inGuilds(_ guilds: [String]) -> String {
        "In \(guilds.formatted(.list(type: .and)))"
    }

    /// "Heard by Maya Ortiz", "Seen by you".
    static func byline(_ item: FeedItem) -> String {
        "\(item.method.title) by \(finder(item))"
    }

    /// "Heard again by Maya Ortiz", "Seen again by you".
    static func againByline(_ item: FeedItem) -> String {
        "\(item.method.title) again by \(finder(item))"
    }

    private static func finder(_ item: FeedItem) -> String {
        item.isMine ? "you" : item.owner.name
    }

    /// The finder at the start of a sentence.
    private static func subject(_ item: FeedItem) -> String {
        item.isMine ? "You" : item.owner.name
    }

    /// The finder by first name, in a row's headline, where it sits beside the patch.
    private static func familiar(_ item: FeedItem) -> String {
        item.isMine ? "You" : item.owner.firstName
    }

    /// "Maya sewed a new patch", "You sewed a new patch"; "Maya shared a sighting" for a repeat shared by hand.
    static func headline(_ item: FeedItem) -> String {
        "\(familiar(item)) \(item.newPatch ? "sewed a new patch" : "shared a sighting")"
    }

    /// "Maya Ortiz sewed a new patch", on the find's own page; "Jo Park heard this bird again" for a repeat.
    static func fullHeadline(_ item: FeedItem) -> String {
        let again = "\(verb(item)) this bird again"
        return "\(subject(item)) \(item.newPatch ? "sewed a new patch" : isLed(item) ? "shared a sighting" : again)"
    }

    /// "Heard in Pasadena, 2 hours ago", "Seen at a secret spot, 2 hours ago", or "Heard, 2 hours ago" without a place.
    static func howAndWhere(_ item: FeedItem) -> String {
        "\(item.method.title)\(inPlace(item)), \(when(item))"
    }

    /// "Maya Ortiz heard a Black Phoebe again in Pasadena, 2 hours ago", "You saw an Acorn Woodpecker again, 2 hours ago".
    static func seenAgainLine(_ item: FeedItem) -> String {
        "\(subject(item)) \(verb(item)) \(CardText.article(for: item.commonName)) \(item.commonName) again\(inPlace(item)), \(when(item))"
    }

    private static func verb(_ item: FeedItem) -> String {
        item.method == .seen ? "saw" : "heard"
    }

    /// "3 more sightings from Lee Birder, 2 hours ago": a member's gathered repeats, by the newest. Sightings, since a line can hold
    /// one bird twice.
    static func gatheredLine(_ items: [FeedItem]) -> String {
        guard let newest = items.first else { return "" }
        return "\(items.count) more sightings from \(finder(newest)), \(when(newest))"
    }

    /// "House Finch and Mourning Dove": each bird in a line of repeats, once.
    static func birds(_ items: [FeedItem]) -> String {
        var names: [String] = []
        for item in items where !names.contains(item.commonName) { names.append(item.commonName) }
        return names.formatted(.list(type: .and))
    }

    /// "3 more sightings from Lee Birder, 2 hours ago. House Finch and Mourning Dove."
    static func spokenLine(_ items: [FeedItem], guilds: [String]? = nil) -> String {
        var parts = [gatheredLine(items), birds(items)]
        if let guilds, !guilds.isEmpty { parts.append(inGuilds(guilds)) }
        return parts.joined(separator: ". ")
    }

    /// "Pasadena, 2 hours ago", or the time alone without a place.
    static func whereAndWhen(_ item: FeedItem) -> String {
        guard let place = item.place else { return when(item) }
        return "\(place == FindPolicy.secretSpot ? "At a secret spot" : place), \(when(item))"
    }

    private static func when(_ item: FeedItem) -> String {
        item.foundAt.formatted(.relative(presentation: .named, unitsStyle: .wide))
    }

    /// " in Pasadena", " at a secret spot", or nothing without a place.
    private static func inPlace(_ item: FeedItem) -> String {
        guard let place = item.place else { return "" }
        return place == FindPolicy.secretSpot ? " at a secret spot" : " in \(place)"
    }

    /// The labels a find wears: First for the Guild, then Rare or Exceptional. Common and Uncommon aren't marked, and a new
    /// patch says so in its headline.
    static func marks(_ item: FeedItem) -> [String] {
        var marks: [String] = []
        if item.circleFirst { marks.append(firstForTheGuild) }
        if let rarity = item.rarity, rarity == .rare || rarity == .exceptional { marks.append(rarity.title) }
        return marks
    }

    static let firstForTheGuild = "First for the Guild"
    static let newPatch = "New patch"
}

/// The marks in a row that wraps at large text sizes.
struct FlowMarks: View {
    let marks: [String]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { ForEach(marks, id: \.self) { WovenMark(title: $0) } }
            VStack(alignment: .leading, spacing: 6) { ForEach(marks, id: \.self) { WovenMark(title: $0) } }
        }
    }
}

/// A find's label, woven and sewn on at its two ends like a real one: card stock's ivory with a fold of stitches each side. It's an
/// object you could hold, not a control, and it keeps its own dark ink in both appearances. No gold (#132).
private struct WovenMark: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String

    var body: some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.cardInk)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .background(Color.cardStock, in: RoundedRectangle(cornerRadius: 2))
            .overlay {
                HStack {
                    SewnEnd()
                    Spacer(minLength: 0)
                    SewnEnd()
                }
                .accessibilityHidden(true)
            }
            .overlay {
                if colorScheme == .light {
                    RoundedRectangle(cornerRadius: 2).strokeBorder(Color.cardEdge.opacity(0.55), lineWidth: 0.75)
                }
            }
            .environment(\.colorScheme, .light)
            .shadow(color: .black.opacity(0.28), radius: 1.5, x: 0, y: 1)
    }
}

/// The stitches that hold down one end of a woven label.
private struct SewnEnd: View {
    var body: some View {
        Canvas { context, size in
            var y: CGFloat = 1.5
            while y < size.height - 1 {
                context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 2)), with: .color(Color.cardEdge.opacity(0.75)))
                y += 4
            }
        }
        .frame(width: 3)
        .padding(.horizontal, 1)
        .allowsHitTesting(false)
    }
}

/// What a card shared by hand to this Guild adds (issue #66): its caption, the finder's note and their original
/// photo, faces blurred.
struct SharedCardExtras: View {
    let card: FeedItem.SharedCard

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let caption = card.caption {
                Text(caption).font(JournalFont.supporting.italic()).foregroundStyle(Color.ink).boardLabel()
            }
            if let note = card.note {
                Text("“\(note)”").font(JournalFont.supporting).foregroundStyle(Color.ink).boardLabel()
            }
            if let url = card.photo?.url {
                Color.raised
                    .aspectRatio(3 / 2, contentMode: .fit)
                    .overlay {
                        AsyncImage(url: url) { phase in
                            if let image = phase.image { image.resizable().scaledToFill() } else { ProgressView() }
                        }
                        .allowsHitTesting(false)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: JournalLayout.thumbnailRadius, style: .continuous))
                    .allowsHitTesting(false)
                    .accessibilityLabel("Their photo")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 4)
        .accessibilityIdentifier("shared-card-extras")
    }
}

/// What leads a find (guide 2.0 page 8): the finder's patch in its edition at about `side` points, a little larger with the text.
struct FindPatch: View {
    let item: FeedItem
    let side: CGFloat

    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        let shown = min(side * scale, side * 1.3)
        FindPatchPicture(item: item)
            .frame(width: shown, height: shown)
            .holdsPatchLight()
    }
}

/// A find's patch, lit like every other. A phone without that edition's pack shows the patch's thumbnail from the art CDN if the
/// server names that edition's, then the edition's blank with the bird's name on its tag: a pack without patches (#58), a stored
/// find naming a watercolour's thumbnail (retired by #137). A plain bitmap under the shader, on the two-at-a-time queue. Never
/// another edition's patch. An edition this phone has never heard of (the server doesn't check it) is the plain blank, like
/// Uncharted's. A decoration: the row or the page says what it is.
struct FindPatchPicture: View {
    @Environment(PackLibrary.self) private var library
    let item: FeedItem
    var size = PatchTextures.Size.thumbnail

    var body: some View {
        let state = library.patchArtState(scientificName: item.scientificName, setID: item.edition)
        Group {
            if state.art == nil, state != .beingSewn, let url = Self.thumbnail(of: item) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFit() } else { patch(state) }
                }
            } else {
                patch(state)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func patch(_ state: PatchArtState) -> some View {
        PatchView(state: state, edition: PatchEdition.of(setID: item.edition), size: size, tag: item.commonName)
    }

    /// The thumbnail on the art CDN, if it's this find's edition's patch: the key is the finder's phone's word, like the edition.
    static func thumbnail(of item: FeedItem) -> URL? {
        guard let art = item.art, let edition = item.edition, art.key.hasPrefix("packs/\(edition)/patch/") else { return nil }
        return art.patchThumbnailURL
    }
}

extension FeedItem.Owner {
    /// "Maya", from "Maya Ortiz".
    var firstName: String { name.split(separator: " ").first.map(String.init) ?? name }

    /// Avatars are initials only (spec v2, "Accounts and the app client").
    var initials: String {
        name.split(whereSeparator: \.isWhitespace).prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}
