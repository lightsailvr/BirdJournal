import Album
import Pack
import SwiftUI

/// A circle's Recent finds (issue #62): friends' sightings, newest first, a page at a time, each with its art, who
/// found it, Heard or Seen, the city or "a secret spot", and when. "First for the circle" marks the earliest surviving
/// find of a species, apart from anyone's Legendary, which is the finder's own first.
struct CircleFeedSection: View {
    @Environment(CircleStore.self) private var circles
    let circleID: String

    private var feed: CircleStore.Feed { circles.feeds[circleID] ?? .init() }

    var body: some View {
        Section {
            if feed.items.isEmpty {
                if feed.isLoaded {
                    Text("No finds yet. Birds your circle adds while sharing show here.")
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
                FindRow(item: item)
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
    }
}

/// One find: the art, the bird, who found it and how, where and when, and its marks.
struct FindRow: View {
    let item: FeedItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            FindArt(item: item)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: JournalLayout.thumbnailRadius, style: .continuous))
                // A scaled-to-fill picture still takes touches outside its clip.
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.commonName).font(JournalFont.rowTitle)
                Text(Self.byline(item)).font(JournalFont.supporting).foregroundStyle(Color.inkSecondary)
                Text(Self.whereAndWhen(item)).font(JournalFont.supporting).foregroundStyle(Color.inkSecondary)
                let marks = Self.marks(item)
                if !marks.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(marks, id: \.self) { mark in FindMark(title: mark) }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("find-\(item.sightingID)")
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

    /// The marks a find wears, in this order: Legendary (the finder's first), First for the circle, and Rare or
    /// Exceptional. Common and Uncommon aren't marked.
    static func marks(_ item: FeedItem) -> [String] {
        var marks: [String] = []
        if item.legendary { marks.append("Legendary") }
        if item.circleFirst { marks.append("First for the circle") }
        if let rarity = item.rarity, rarity == .rare || rarity == .exceptional { marks.append(rarity.title) }
        return marks
    }
}

private struct FindMark: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(title == "Legendary" ? Color.goldInk : Color.mossText)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(title == "Legendary" ? Color.goldWash : Color.moss.opacity(0.18), in: .capsule)
    }
}

/// The find's art from the art CDN; until it loads, or when it can't, the species' reference photo from an installed
/// pack, else a typographic tile naming the bird.
private struct FindArt: View {
    @Environment(PackLibrary.self) private var library
    let item: FeedItem

    var body: some View {
        if let url = item.art?.url {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    fallback
                }
            }
        } else {
            fallback
        }
    }

    @ViewBuilder private var fallback: some View {
        if let url = library.thumbnailURL(scientificName: item.scientificName), let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            ZStack {
                Color.cardFace
                Text(item.commonName)
                    .font(.system(.caption2, design: .serif, weight: .medium))
                    .foregroundStyle(Color.cardIvory)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
                    .padding(5)
            }
        }
    }
}
