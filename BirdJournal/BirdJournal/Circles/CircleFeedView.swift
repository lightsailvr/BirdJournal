import Album
import Pack
import SwiftUI

/// A Guild's Recent finds (issue #62; guide 2.0 page 8, issue #136): friends' sightings, newest first, a page at a time. A
/// new patch is led by the finder's patch, with the bird, how and where they met it, and when; a repeat sighting is a
/// quieter "saw a House Finch again" line. "First for the Guild" marks the earliest surviving find of a species, apart
/// from a new patch. Under each find, its reactions (issue #64): a friend's find takes a tap on each, the birder's own
/// shows what friends gave. No comments.
struct CircleFeedSection: View {
    @Environment(CircleStore.self) private var circles
    let circleID: String
    /// Report a friend's find, and block its owner (issue #71): the Guild's page presents the sheet and the dialog,
    /// since a sheet hung on a list section never presents.
    var onReport: (FeedItem) -> Void = { _ in }
    var onBlock: (FeedItem.Owner) -> Void = { _ in }
    @State private var reactionError: String?

    private var feed: CircleStore.Feed { circles.feeds[circleID] ?? .init() }

    var body: some View {
        Section {
            if feed.items.isEmpty {
                if feed.isLoaded {
                    StateNotice("No finds yet", message: "Birds your Guild adds while sharing show here.")
                        .accessibilityIdentifier("feedEmpty")
                } else if let error = feed.error {
                    Text(error).font(JournalFont.supporting).foregroundStyle(Color.inkSecondary)
                } else {
                    GuildPlaceholder()
                }
            }
            ForEach(feed.items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    FindRow(item: item)
                        // Clear of the menu at the row's corner.
                        .padding(.trailing, item.isMine ? 0 : 30)
                    ReactionBar(item: item) { kind, given in react(kind, given: given, to: item) }
                }
                // The whole row's width, so the menu sits in one place on every row.
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .overlay(alignment: .topTrailing) {
                    if !item.isMine {
                        // Report and Block in plain sight (issue #150); touch and hold still works.
                        Menu {
                            menuItems(item)
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Color.inkSecondary)
                                .frame(width: 44, height: 44)
                                .contentShape(.rect)
                        }
                        .menuStyle(.button)
                        // In a list row every button would otherwise take the row's tap.
                        .buttonStyle(.borderless)
                        .accessibilityLabel("More about \(item.owner.name)'s \(item.commonName)")
                        // Not "find-…": that's how the tests pick out the find rows themselves.
                        .accessibilityIdentifier("menu-find-\(item.sightingID)")
                        .offset(x: 10, y: -6)
                    }
                }
                .contextMenu {
                    if !item.isMine {
                        menuItems(item)
                    }
                }
            }
            if let reactionError {
                InlineError(reactionError)
            }
            if feed.nextCursor != nil {
                Button {
                    Task { await circles.loadMoreFeed(circleID: circleID) }
                } label: {
                    if feed.isLoading { ProgressView().frame(maxWidth: .infinity) } else { Text("More finds") }
                }
                .disabled(feed.isLoading)
                .accessibilityIdentifier("feedMore")
            }
            if let error = feed.error, !feed.items.isEmpty {
                InlineError(error)
            }
        } header: {
            Text("Recent finds")
        }
    }

    @ViewBuilder private func menuItems(_ item: FeedItem) -> some View {
        Button("Report this find…", systemImage: "exclamationmark.bubble") { onReport(item) }
        Button("Block \(item.owner.name)…", systemImage: "hand.raised", role: .destructive) { onBlock(item.owner) }
    }

    private func react(_ kind: ReactionKind, given: Bool, to item: FeedItem) {
        Task {
            do {
                try await circles.react(kind, given: given, to: item)
                reactionError = nil
            } catch {
                reactionError = CircleStore.message(for: error, doing: "send your reaction")
            }
        }
    }
}

/// A find's reactions: on a friend's find, the three fixed ones to tap (again to take back), each with its count; on
/// the birder's own, only what friends gave, not tappable. No comments.
struct ReactionBar: View {
    let item: FeedItem
    let react: (ReactionKind, Bool) -> Void

    var body: some View {
        if item.isMine {
            let given = item.reactions.filter { $0.count > 0 }
            if !given.isEmpty {
                Text(Self.summary(given))
                    .font(.caption)
                    .foregroundStyle(Color.inkSecondary)
                    .accessibilityIdentifier("reactions-\(item.sightingID)")
            }
        } else {
            ViewThatFits(in: .horizontal) {
                buttons(titled: true, symbols: true)
                buttons(titled: true, symbols: false)
                buttons(titled: false, symbols: true)
            }
        }
    }

    /// "Lovely find 2, Let's go together 1".
    static func summary(_ counts: [ReactionCount]) -> String {
        counts.map { "\($0.kind.title) \($0.count)" }.joined(separator: ", ")
    }

    private func buttons(titled: Bool, symbols: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(ReactionKind.allCases) { kind in
                let count = item.reaction(kind)
                Button {
                    react(kind, !count.mine)
                } label: {
                    HStack(spacing: 4) {
                        if symbols { Image(systemName: kind.symbol) }
                        if titled { Text(kind.title) }
                        if count.count > 0 { Text("\(count.count)").monospacedDigit() }
                    }
                    .font(.caption.weight(count.mine ? .semibold : .regular))
                    .foregroundStyle(count.mine ? AnyShapeStyle(Color.mossText) : AnyShapeStyle(TintShapeStyle.tint))
                    .padding(.horizontal, symbols ? 9 : 8)
                    .padding(.vertical, 5)
                    .background(count.mine ? AnyShapeStyle(TintShapeStyle.tint) : AnyShapeStyle(TintShapeStyle.tint.opacity(0.1)), in: .capsule)
                    .fixedSize()
                    // The pill stays small; what a thumb can hit is 44 pt tall (issue #150).
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                }
                // In a list row every button would otherwise take the row's tap.
                .buttonStyle(.borderless)
                .accessibilityLabel(kind.title)
                .accessibilityValue(count.count == 1 ? "1 reaction" : "\(count.count) reactions")
                .accessibilityAddTraits(count.mine ? .isSelected : [])
                .accessibilityIdentifier("react-\(kind.rawValue)-\(item.sightingID)")
            }
        }
    }
}

/// One find (guide 2.0 page 8). A new patch, or a card shared by hand, is led by the patch: who sewed it, then the bird,
/// how and where they met it, when, and its marks. A repeat sighting is one quiet line with its marks. VoiceOver reads
/// the bird first, either way.
struct FindRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let item: FeedItem

    var body: some View {
        Group {
            if Self.isLed(item) {
                led
            } else {
                seenAgain
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(item))
        .accessibilityIdentifier("find-\(item.sightingID)")
    }

    private var led: some View {
        VStack(alignment: .leading, spacing: 10) {
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
            layout {
                FindPatch(item: item)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.headline(item)).font(JournalFont.attribution).foregroundStyle(Color.inkSecondary)
                    Text(item.commonName).font(JournalFont.heading).foregroundStyle(Color.ink)
                    Text(Self.howAndWhere(item)).font(JournalFont.attribution).foregroundStyle(Color.inkSecondary)
                    marks.padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
            if let card = item.card {
                SharedCardExtras(card: card)
            }
        }
    }

    /// "Maya Ortiz heard a Black Phoebe again in Pasadena, 2 hours ago".
    private var seenAgain: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Self.seenAgainLine(item)).font(JournalFont.supporting).foregroundStyle(Color.inkSecondary)
            marks
        }
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
    /// caption and note; a repeat says "Heard again by Maya Ortiz".
    static func spoken(_ item: FeedItem) -> String {
        var parts = [item.commonName, isLed(item) ? byline(item) : againByline(item), whereAndWhen(item)]
        if item.newPatch { parts.append(newPatch) }
        parts += marks(item)
        if let caption = item.card?.caption { parts.append(caption) }
        if let note = item.card?.note { parts.append("Note: \(note)") }
        if item.card?.photo?.url != nil { parts.append("With their photo") }
        return parts.joined(separator: ". ")
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

    /// "Maya Ortiz sewed a new patch", "You sewed a new patch"; "Maya Ortiz shared a sighting" for a repeat shared by hand.
    static func headline(_ item: FeedItem) -> String {
        "\(subject(item)) \(item.newPatch ? "sewed a new patch" : "shared a sighting")"
    }

    /// "Heard in Pasadena, 2 hours ago", "Seen at a secret spot, 2 hours ago", or "Heard, 2 hours ago" without a place.
    static func howAndWhere(_ item: FeedItem) -> String {
        "\(item.method.title)\(inPlace(item)), \(when(item))"
    }

    /// "Maya Ortiz heard a Black Phoebe again in Pasadena, 2 hours ago", "You saw an Acorn Woodpecker again, 2 hours ago".
    static func seenAgainLine(_ item: FeedItem) -> String {
        let verb = item.method == .seen ? "saw" : "heard"
        return "\(subject(item)) \(verb) \(CardText.article(for: item.commonName)) \(item.commonName) again\(inPlace(item)), \(when(item))"
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
private struct FlowMarks: View {
    let marks: [String]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { ForEach(marks, id: \.self) { FindMark(title: $0) } }
            VStack(alignment: .leading, spacing: 6) { ForEach(marks, id: \.self) { FindMark(title: $0) } }
        }
    }
}

/// What a card shared by hand to this Guild adds (issue #66): its caption, the finder's note and their original
/// photo, faces blurred.
private struct SharedCardExtras: View {
    let card: FeedItem.SharedCard

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let caption = card.caption {
                Text(caption).font(JournalFont.supporting.italic()).foregroundStyle(Color.ink)
            }
            if let note = card.note {
                Text("“\(note)”").font(JournalFont.supporting).foregroundStyle(Color.ink)
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
                    .accessibilityLabel("Their photo")
            }
        }
        .padding(.top, 4)
        .accessibilityIdentifier("shared-card-extras")
    }
}

/// A find's label. First for the Guild is a small aqua one; a rarity is just its word. No gold (#132).
private struct FindMark: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let title: String

    var body: some View {
        let first = title == FindRow.firstForTheGuild
        let shape = RoundedRectangle(cornerRadius: JournalLayout.outlineRadius(typeSize, wrapped: 8), style: .continuous)
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(first ? AnyShapeStyle(TintShapeStyle.tint) : AnyShapeStyle(Color.inkSecondary))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .overlay(shape.strokeBorder(first ? AnyShapeStyle(TintShapeStyle.tint) : AnyShapeStyle(Color.rule), lineWidth: 1))
    }
}

/// What leads a find (guide 2.0 page 8): the finder's patch in its edition, lit like every other. A phone without that
/// edition's pack shows the patch's thumbnail from the art CDN, then the edition's blank: a pack without patches (#58), a
/// stored find naming a watercolour's thumbnail (retired by #137). Never another edition's patch.
private struct FindPatch: View {
    @Environment(PackLibrary.self) private var library
    let item: FeedItem

    private static let side: CGFloat = 76

    var body: some View {
        Group {
            if let art = library.patchArt(scientificName: item.scientificName, setID: item.edition) {
                PatchView(art: art, edition: PatchEdition.of(setID: item.edition))
            } else if let url = item.art?.patchThumbnailURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFit() } else { fallback }
                }
            } else {
                fallback
            }
        }
        .frame(width: Self.side, height: Self.side)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .holdsPatchLight()
    }

    @ViewBuilder private var fallback: some View {
        let edition = PatchEdition.of(setID: item.edition)
        PatchBlank(edition: edition).aspectRatio(edition.aspect, contentMode: .fit)
    }
}
