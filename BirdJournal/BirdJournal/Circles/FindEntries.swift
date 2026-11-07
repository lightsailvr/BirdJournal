import Foundation

/// One find on a feed (issue #150): the find, and the Guilds it's in. A find shared to two Guilds is one entry naming both.
struct FindEntry: Equatable, Identifiable, Sendable {
    var item: FeedItem
    /// The Guilds it's in, in the order the birder's Guilds are listed.
    var circleIDs: [String]

    var id: String { item.id }

    /// The finds of several Guilds' pages as one list, newest first, one entry per owner and sighting. The server orders a feed
    /// by time, then owner and sighting, so this does too. The blocked are left out, wherever the block was made.
    ///
    /// Each Guild's copy of a find can say something different: a card shared by hand to one, with its place left out, and the
    /// same sighting found automatically in another. An entry shows what's in any copy, but never more of where the bird was
    /// than the copy that says least: a secret spot stays one and a place left out stays out.
    static func merging(_ feeds: [(circleID: String, items: [FeedItem])], blocked: Set<String> = []) -> [FindEntry] {
        var entries: [String: FindEntry] = [:]
        for (circleID, items) in feeds {
            for item in items where !blocked.contains(item.owner.id) {
                guard var entry = entries[item.id] else {
                    entries[item.id] = FindEntry(item: item, circleIDs: [circleID])
                    continue
                }
                if !entry.circleIDs.contains(circleID) { entry.circleIDs.append(circleID) }
                entry.item = entry.item.joined(with: item)
                entries[item.id] = entry
            }
        }
        return entries.values.sorted { ($0.item.foundAt, $0.item.id) > ($1.item.foundAt, $1.item.id) }
    }
}

private extension FeedItem {
    /// This copy of a find, with what another Guild's copy adds.
    func joined(with other: FeedItem) -> FeedItem {
        var joined = self
        joined.card = card ?? other.card
        joined.circleFirst = circleFirst || other.circleFirst
        joined.newPatch = newPatch || other.newPatch
        joined.edition = edition ?? other.edition
        joined.art = art ?? other.art
        switch (place, other.place) {
        case (nil, _), (_, nil): joined.place = nil
        case (FindPolicy.secretSpot, _), (_, FindPolicy.secretSpot): joined.place = FindPolicy.secretSpot
        default: break
        }
        return joined
    }
}

/// A feed's rows (issue #150, G4): each find on its own, except that a member's consecutive repeats within a day are gathered
/// into one line, so they don't push new patches off the screen. A new patch, a card shared by hand and anything with a mark
/// (First for the Guild, Rare, Exceptional) always stands on its own, and ends the line. Two repeats make a line; one is just
/// a quiet row.
enum FindFeedRow: Equatable, Identifiable {
    case find(FindEntry)
    case repeats([FindEntry])

    /// A line gathers what's within a day of its newest find.
    static let window: TimeInterval = 86_400

    var id: String {
        switch self {
        case .find(let entry): entry.id
        // By its oldest, so a repeat landing at its head leaves it the same row, and the reader's place.
        case .repeats(let entries): "repeats-\(entries.last?.id ?? "")"
        }
    }

    /// Whether this find can go in a line.
    static func isGathered(_ item: FeedItem) -> Bool {
        !FindRow.isLed(item) && FindRow.marks(item).isEmpty
    }

    /// Finds, newest first, as rows.
    static func rows(of entries: [FindEntry]) -> [FindFeedRow] {
        var rows: [FindFeedRow] = []
        var line: [FindEntry] = []
        func endLine() {
            if line.count > 1 {
                rows.append(.repeats(line))
            } else if let only = line.first {
                rows.append(.find(only))
            }
            line = []
        }
        for entry in entries {
            guard isGathered(entry.item) else {
                endLine()
                rows.append(.find(entry))
                continue
            }
            if let newest = line.first,
               newest.item.owner.id != entry.item.owner.id || newest.item.foundAt.timeIntervalSince(entry.item.foundAt) > window {
                endLine()
            }
            line.append(entry)
        }
        endLine()
        return rows
    }
}
