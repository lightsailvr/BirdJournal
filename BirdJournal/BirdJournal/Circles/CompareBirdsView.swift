import Album
import SwiftData
import SwiftUI

/// Compare birds (issue #64): the birder and a friend side by side, each species Heard, Seen or not yet found. The
/// friend's side is the server's (their finds in the circles the two share, Seen beating Heard); the birder's comes
/// from the collection on this phone, so private sightings count too and nothing of it is sent. Pure, for the tests.
struct BirdComparison: Equatable {
    struct Row: Equatable, Identifiable {
        var scientificName: String
        var commonName: String
        /// The birder's best, nil when not yet found.
        var mine: SightingMethod?
        var theirs: SightingMethod?

        var id: String { scientificName }
    }

    /// What the friend has found and the birder hasn't: the next walk.
    var onlyTheirs: [Row]
    var onlyMine: [Row]
    var both: [Row]

    var myCount: Int { onlyMine.count + both.count }
    var theirCount: Int { onlyTheirs.count + both.count }

    /// `mine` is every sighting's BirdNET label and method; species meet by scientific name.
    init(mine: [(speciesID: String, method: SightingMethod)], theirs: [FriendBirds.Species]) {
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
        var rows: [Row] = []
        for name in Set(myBest.keys).union(theirBest.keys) {
            rows.append(Row(
                scientificName: name,
                commonName: theirBest[name]?.commonName ?? myBest[name]?.common ?? name,
                mine: myBest[name]?.method,
                theirs: theirBest[name]?.method
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
}

struct CompareBirdsView: View {
    @Environment(CircleStore.self) private var circles
    @Query private var sightings: [Sighting]
    let friendID: String
    let friendName: String
    @State private var error: String?

    /// What was last read of the friend, drawn at once and refreshed in place.
    private var friend: FriendBirds? { circles.friendBirds[friendID] }

    private var firstName: String { friendName.split(separator: " ").first.map(String.init) ?? friendName }

    var body: some View {
        PaperList {
            if let friend {
                let comparison = BirdComparison(mine: sightings.map { ($0.speciesID, $0.method) }, theirs: friend.species)
                Section {
                    HStack(spacing: 0) {
                        tally("You", comparison.myCount)
                        tally(firstName, comparison.theirCount)
                        tally("Both", comparison.both.count)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("compareTally")
                } footer: {
                    Text("\(firstName)'s side is what they shared to Guilds you're both in. Yours is everything on this iPhone.")
                }
                if comparison.onlyTheirs.isEmpty, comparison.onlyMine.isEmpty, comparison.both.isEmpty {
                    Section {
                        Text("Neither of you has found a bird yet.")
                            .font(JournalFont.supporting)
                            .foregroundStyle(Color.inkSecondary)
                    }
                }
                rows(comparison.onlyTheirs, header: "\(firstName) has, you haven't yet")
                rows(comparison.both, header: "You both have")
                rows(comparison.onlyMine, header: "Only you")
            } else if let error {
                Section {
                    Text(error).foregroundStyle(Color.inkSecondary)
                    Button("Try again") { Task { await load() } }
                }
            } else {
                Section { GuildPlaceholder(rows: 4) }
            }
        }
        .navigationTitle("You and \(firstName)")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func tally(_ who: String, _ count: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(count)").font(.title2.weight(.semibold)).foregroundStyle(Color.ink)
            Text(who).font(JournalFont.supporting).foregroundStyle(Color.inkSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func rows(_ rows: [BirdComparison.Row], header: String) -> some View {
        if !rows.isEmpty {
            Section {
                ForEach(rows) { row in
                    CompareRow(row: row, friendName: firstName)
                }
            } header: {
                HStack {
                    Text("\(header) · \(rows.count)")
                    Spacer()
                    Text("You").frame(width: CompareRow.column)
                    Text(firstName).lineLimit(1).frame(width: CompareRow.column)
                }
            }
        }
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

private struct CompareRow: View {
    static let column: CGFloat = 64
    let row: BirdComparison.Row
    let friendName: String

    var body: some View {
        HStack {
            Text(row.commonName).font(JournalFont.rowTitle)
            Spacer(minLength: 8)
            MethodBadge(method: row.mine).frame(width: Self.column)
            MethodBadge(method: row.theirs).frame(width: Self.column)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.commonName). You: \(BirdComparison.word(row.mine)). \(friendName): \(BirdComparison.word(row.theirs)).")
        .accessibilityIdentifier("compare-\(row.scientificName)")
    }
}

private struct MethodBadge: View {
    let method: SightingMethod?

    var body: some View {
        switch method {
        case .seen:
            Text("Seen")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.mossText)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.moss, in: .capsule)
        case .heard:
            Text("Heard")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.moss)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .overlay(Capsule().strokeBorder(Color.moss, lineWidth: 1))
        case nil:
            Text("Not yet")
                .font(.caption)
                .foregroundStyle(Color.inkSecondary)
        }
    }
}
