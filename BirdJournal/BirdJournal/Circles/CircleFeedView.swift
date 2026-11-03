import Album
import Pack
import SwiftUI

/// A Guild's Recent finds (issue #62, led by the artwork since #118): friends' sightings, newest first, a page at a
/// time, each with who found it, the city or "a secret spot" and when, then the art, the bird and Heard or Seen.
/// "First for the Guild" marks the earliest surviving find of a species, apart from anyone's Legendary, which is the
/// finder's own first. Under each find, its reactions (issue #64): a friend's find takes a tap on each, the birder's
/// own shows what friends gave. No comments.
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
                    Text("No finds yet. Birds your Guild adds while sharing show here.")
                        .font(JournalFont.supporting)
                        .foregroundStyle(Color.inkSecondary)
                        .accessibilityIdentifier("feedEmpty")
                } else if let error = feed.error {
                    Text(error).font(JournalFont.supporting).foregroundStyle(Color.inkSecondary)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            ForEach(feed.items) { item in
                VStack(alignment: .leading, spacing: 10) {
                    FindRow(item: item)
                    ReactionBar(item: item) { kind, given in react(kind, given: given, to: item) }
                }
                .padding(.vertical, 6)
                .contextMenu {
                    if !item.isMine {
                        Button("Report this find…", systemImage: "exclamationmark.bubble") { onReport(item) }
                        Button("Block \(item.owner.name)…", systemImage: "hand.raised", role: .destructive) { onBlock(item.owner) }
                    }
                }
            }
            if let reactionError {
                Text(reactionError).font(JournalFont.supporting).foregroundStyle(.red)
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
                Text(error).font(JournalFont.supporting).foregroundStyle(.red)
            }
        } header: {
            Text("Recent finds")
        }
        .listRowBackground(Color.raised)
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

    /// "Lovely find 2 · Let's go together 1".
    static func summary(_ counts: [ReactionCount]) -> String {
        counts.map { "\($0.kind.title) \($0.count)" }.joined(separator: " · ")
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
                    .foregroundStyle(count.mine ? Color.mossText : Color.moss)
                    .padding(.horizontal, symbols ? 9 : 8)
                    .padding(.vertical, 5)
                    .background(count.mine ? Color.moss : Color.moss.opacity(0.1), in: .capsule)
                    .fixedSize()
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

/// One find, artwork first (design guide pages 3 and 13): who found it, where and when, and its marks; then the art;
/// then the bird and Heard or Seen. VoiceOver reads the bird first.
struct FindRow: View {
    let item: FeedItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Text(Self.initials(item.owner.name))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.mossText)
                    .frame(width: 34, height: 34)
                    .background(Color.moss, in: .circle)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.isMine ? "You" : item.owner.name).font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
                    Text(Self.whereAndWhen(item)).font(JournalFont.attribution).foregroundStyle(Color.inkSecondary)
                }
                Spacer(minLength: 6)
            }
            let marks = Self.marks(item)
            if !marks.isEmpty {
                FlowMarks(marks: marks)
            }
            FindArt(item: item)
                .clipShape(RoundedRectangle(cornerRadius: JournalLayout.thumbnailRadius, style: .continuous))
                // A scaled-to-fill picture still takes touches outside its clip.
                .allowsHitTesting(false)
            HStack(alignment: .firstTextBaseline) {
                Text(item.commonName).font(JournalFont.heading).foregroundStyle(Color.ink)
                Spacer(minLength: 8)
                Text(item.method.title).font(JournalFont.supporting).foregroundStyle(Color.inkSecondary)
            }
            if let card = item.card {
                SharedCardExtras(card: card)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(item))
        .accessibilityIdentifier("find-\(item.sightingID)")
    }

    /// "Black Phoebe. Heard by Maya Ortiz. Pasadena · 2 hours ago. First for the Guild.", then a shared card's caption
    /// and note.
    static func spoken(_ item: FeedItem) -> String {
        var parts = [item.commonName, byline(item), whereAndWhen(item)] + marks(item)
        if let caption = item.card?.caption { parts.append(caption) }
        if let note = item.card?.note { parts.append("Note: \(note)") }
        if item.card?.photo?.url != nil { parts.append("With their photo") }
        return parts.joined(separator: ". ")
    }

    static func initials(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    /// "Heard by Maya Ortiz", "Seen by you".
    static func byline(_ item: FeedItem) -> String {
        "\(item.method.title) by \(item.isMine ? "you" : item.owner.name)"
    }

    /// "Pasadena · 2 hours ago", or the time alone without a place.
    static func whereAndWhen(_ item: FeedItem) -> String {
        let when = item.foundAt.formatted(.relative(presentation: .named, unitsStyle: .wide))
        guard let place = item.place else { return when }
        return "\(place == FindPolicy.secretSpot ? "At a secret spot" : place) · \(when)"
    }

    /// The marks a find wears, in this order: Legendary (the finder's first), First for the Guild, and Rare or
    /// Exceptional. Common and Uncommon aren't marked.
    static func marks(_ item: FeedItem) -> [String] {
        var marks: [String] = []
        if item.legendary { marks.append("Legendary") }
        if item.circleFirst { marks.append(firstForTheGuild) }
        if let rarity = item.rarity, rarity == .rare || rarity == .exceptional { marks.append(rarity.title) }
        return marks
    }

    static let firstForTheGuild = "First for the Guild"
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

/// A find's mark. Legendary keeps the gold, its one job; First for the Guild is an outlined aqua capsule, kept
/// apart from it; a rarity is just its word.
private struct FindMark: View {
    let title: String

    var body: some View {
        let legendary = title == "Legendary"
        let first = title == FindRow.firstForTheGuild
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(legendary ? Color.goldInk : first ? Color.moss : Color.inkSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(legendary ? Color.goldWash : Color.clear, in: .capsule)
            .overlay(Capsule().strokeBorder(first ? Color.moss : legendary ? Color.goldInk.opacity(0.5) : Color.rule, lineWidth: 1))
    }
}

/// The find's art from the art CDN; until it loads, or when it can't, the species' painting from an installed pack
/// (the same pack art the find names), else its reference photo, else a typographic tile naming the bird. A pack
/// painting sits whole on the card's ivory, as on the card: it is painted to its edges.
private struct FindArt: View {
    @Environment(PackLibrary.self) private var library
    let item: FeedItem

    var body: some View {
        if let url = item.art?.url {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    if item.art?.kind == "pack" { painting(image) } else { filled(image) }
                } else {
                    fallback
                }
            }
        } else {
            fallback
        }
    }

    /// A pack painting, whole on the ivory face in a square slot.
    private func painting(_ image: Image) -> some View {
        Color.cardFace
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay { image.resizable().scaledToFit().padding(.vertical, 6) }
    }

    /// A painted scene, the birder's photo art or a reference photo, filling a 4:3 slot.
    private func filled(_ image: Image) -> some View {
        Color.raised
            .aspectRatio(4 / 3, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay { image.resizable().scaledToFill() }
            .clipped()
    }

    @ViewBuilder private var fallback: some View {
        if let art = library.packArt(scientificName: item.scientificName, setID: nil) {
            // Decoded off the main actor, feathered into the face as on the card.
            Color.cardFace
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay { PackImage(url: art.pack.artURL(for: art.art), painting: true).padding(.vertical, 6) }
        } else if let url = library.thumbnailURL(scientificName: item.scientificName) {
            PackImage(url: url)
                .aspectRatio(4 / 3, contentMode: .fit)
                .frame(maxWidth: .infinity)
        } else {
            ZStack {
                Color.cardFace
                Text(item.commonName)
                    .font(.system(.title3, design: .serif, weight: .medium))
                    .foregroundStyle(Color.cardIvory)
                    .multilineTextAlignment(.center)
                    .padding(12)
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            .frame(maxWidth: .infinity)
        }
    }
}
