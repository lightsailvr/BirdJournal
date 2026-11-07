#if DEBUG
import Album
import Foundation
import SwiftUI

/// Says when `-fakeLateFinds` has landed, where only a UI test will read it (issue #150), so it can compare a row before and after.
@MainActor @Observable
final class LateFindsProbe {
    static let shared = LateFindsProbe()
    var hasLanded = false
}

struct LateFindsProbeView: View {
    var body: some View {
        if LateFindsProbe.shared.hasLanded {
            Text("landed")
                .font(.system(size: 1))
                .frame(width: 1, height: 1)
                .clipped()
                .opacity(0.02)
                .allowsHitTesting(false)
                .accessibilityIdentifier("late-finds-landed")
        }
    }
}

/// The debug fake circle server (`-fakeCircles empty|some`, issue #61): circles, members and invites in memory, with
/// the backend's rules (20 members, seven-day invites, the creator removes). The fake account is "Pat Birder"
/// (`fake-sub`). Invite tokens it knows besides its own: `fake-invite` (Canyon Walkers, from Maya), `expired` and
/// `full`. Finds (issue #62) fan out to the circles Pat is in when first put, as on the server; seeded, Sunday Group's
/// feed has friends' finds. Goals (issue #65) follow the server's rules: a monthly goal per circle in its time zone
/// (10 in the first month, else the larger of 5 and 115 % of last month's species), progress as distinct species among
/// the feed's finds in the period, custom goals deleted by their creator or the circle's. Seeded, Sunday Group chases
/// its monthly goal, a running and an upcoming custom goal, and one reached last week.
/// feed has friends' finds. Reactions (issue #64) are counted per find, with a few friends' already on the seeded
/// ones, and Compare birds reads a friend's finds in the circles Pat shares with them. Nothing leaves the phone.
final class FakeCircleClient: CircleClient {
    static let me = "fake-sub"
    static let myName = "Pat Birder"
    private var circlesByID: [String: CircleDetail] = [:]
    private var order: [String] = []
    private var invites: [String: (circleID: String, expiresAt: Date)] = [:]
    private var nextID = 1
    private let now: () -> Date
    /// Every circle's feed items, in no order; the feed sorts them.
    private var feedItems: [String: [FeedItem]] = [:]
    /// The circles each of Pat's finds went to on its first put.
    private var findCircles: [UUID: [String]] = [:]
    /// Every put and delete, for the tests: `put <id>` or `delete <id>`; `card <id>` for a card shared by hand and
    /// `photo <key>` for an uploaded photo.
    private(set) var findLog: [String] = []
    /// The cards shared by hand, as they were sent.
    private(set) var sharedCards: [UUID: FindPolicy.Card] = [:]
    /// The photos uploaded, by key.
    private(set) var photos: [String: Data] = [:]
    /// The phone tokens registered to Pat (issue #63), with their environment.
    private(set) var devices: [String: PushEnvironment] = [:]
    /// Every device registration and removal, for the tests: `register <token> <environment>` or `unregister <token>`.
    private(set) var deviceLog: [String] = []
    private var muted = Mutes()
    /// Reports and blocks (issue #71).
    private(set) var reports: [ReportDraft] = []
    private var blockedIDs: [String] = []
    /// Every circle's goals without their progress, which is counted from the feed when read. `head start` stands in
    /// for seeded finds older than the feed shows, so the seeded goals aren't all at zero.
    private var storedGoals: [String: [(goal: CircleGoal, headStart: Int)]] = [:]
    /// Who gave each reaction, by feed item id.
    private var reactions: [String: [ReactionKind: Set<String>]] = [:]
    /// Every reaction given or taken back, for the tests: `put lovely maya/<id>` or `delete …`.
    private(set) var reactionLog: [String] = []

    /// `-fakeCircles offline` (issue #119): nothing can be read, as with no connection.
    var isOffline = false
    /// `-fakeCircleLatency <seconds>` (issue #150): how long each read takes, as on a slow connection, so the screens' waiting
    /// states can be seen and measured.
    var latency: Duration = .zero

    /// How long Compare's answer takes to come back once the server has read it, for the tests of what lands meanwhile.
    var compareAnswerLatency: Duration = .zero

    /// `-fakeGoalRises <n>` (issue #150): every read of a Guild's goals after the first finds them `n` birds further on, as a
    /// friend's finds would, so a test can see a thread sew on screen.
    var goalRisesBy = 0
    private var goalReads: [String: Int] = [:]
    /// How many times any Guild's goals have been read, for the tests.
    var goalReadCount: Int { goalReads.values.reduce(0, +) }
    /// What a friend has beyond the feed's finds, in Compare, by friend id.
    private var moreCompared: [String: [FriendBirds.Species]] = [:]
    /// Every Compare asked of the server, for the tests.
    private(set) var compareLog: [String] = []

    /// The Guilds whose feeds can't be read, as with a server failing for one, for the tests.
    var failingFeeds: Set<String> = []
    /// `-fakeReactionsFail YES`: no reaction lands, so the screens' failures can be seen.
    var reactionsFail = false

    /// A read's time on the wire, which offline ends in no answer.
    private func wire() async throws {
        if latency > .zero { try? await Task.sleep(for: latency) }
        if isOffline { throw URLError(.notConnectedToInternet) }
    }

    init(seeded: Bool, offline: Bool = false, now: @escaping () -> Date = Date.init) {
        self.now = now
        isOffline = offline
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        if seeded {
            add(name: "Sunday Group", creator: (Self.me, Self.myName), others: [("maya", "Maya Ortiz"), ("jo", "Jo Park"), ("sam", "Sam Okafor")], at: base)
            add(name: "Family", creator: ("dad", "Robin Birder"), others: [(Self.me, Self.myName), ("lee", "Lee Birder")], at: base.addingTimeInterval(86_400))
        }
        if seeded, let sunday = order.first {
            seedFeed(circleID: sunday)
            seedGoals(circleID: sunday)
        }
        let canyon = add(name: "Canyon Walkers", creator: ("maya", "Maya Ortiz"), others: [("ari", "Ari Chen")], at: base)
        invites["fake-invite"] = (canyon, now().addingTimeInterval(6 * 86_400))
        invites["expired"] = (canyon, .distantPast)
        let full = add(name: "Big Year Crew", creator: ("maya", "Maya Ortiz"), others: (2...20).map { ("m\($0)", "Member \($0)") }, at: base)
        invites["full"] = (full, now().addingTimeInterval(6 * 86_400))
    }

    func circles(accessToken: String) async throws -> [CircleSummary] {
        try await wire()
        return order.compactMap { circlesByID[$0] }.filter { $0.members.contains { $0.id == Self.me } }.map { summary($0) }
    }

    func createCircle(named name: String, timeZone: String, accessToken: String) async throws -> CircleDetail {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...40).contains(trimmed.count) else { throw CircleError.rejected }
        let id = add(name: trimmed, creator: (Self.me, Self.myName), others: [], at: now(), timeZone: timeZone)
        return try await circle(id: id, accessToken: accessToken)
    }

    func circle(id: String, accessToken: String) async throws -> CircleDetail {
        try await wire()
        guard let detail = circlesByID[id], detail.members.contains(where: { $0.id == Self.me }) else { throw CircleError.notFound }
        return withViewer(detail)
    }

    func createInvite(circleID: String, accessToken: String) async throws -> CircleInvite {
        _ = try await circle(id: circleID, accessToken: accessToken)
        let token = "fake-\(nextID)-\(UUID().uuidString.prefix(8).lowercased())"
        nextID += 1
        let expires = now().addingTimeInterval(7 * 86_400)
        invites[token] = (circleID, expires)
        return CircleInvite(token: token, url: InviteLink.url(token: token), expiresAt: expires)
    }

    func invitePreview(token: String, accessToken: String) async throws -> InvitePreview {
        try await wire()
        let (detail, expires) = try live(token)
        return InvitePreview(
            circle: summary(detail),
            invitedBy: detail.members.first(where: \.isCreator)?.displayName,
            expiresAt: expires,
            alreadyMember: detail.members.contains { $0.id == Self.me }
        )
    }

    func acceptInvite(token: String, accessToken: String) async throws -> CircleDetail {
        var (detail, _) = try live(token)
        if !detail.members.contains(where: { $0.id == Self.me }) {
            guard detail.members.count < 20 else { throw CircleError.full }
            detail.members.append(CircleMember(id: Self.me, displayName: Self.myName, joinedAt: now(), isCreator: false))
            detail.circle.memberCount = detail.members.count
            circlesByID[detail.circle.id] = detail
            order.removeAll { $0 == detail.circle.id }
            order.append(detail.circle.id)
        }
        return withViewer(detail)
    }

    func leave(circleID: String, accessToken: String) async throws {
        guard var detail = circlesByID[circleID], detail.members.contains(where: { $0.id == Self.me }) else { throw CircleError.notFound }
        detail.members.removeAll { $0.id == Self.me }
        if detail.circle.createdBy == Self.me, let heir = detail.members.first {
            detail.circle.createdBy = heir.id
            detail.members[0].isCreator = true
        }
        detail.circle.memberCount = detail.members.count
        circlesByID[circleID] = detail
    }

    func removeMember(_ memberID: String, circleID: String, accessToken: String) async throws {
        guard var detail = circlesByID[circleID], detail.members.contains(where: { $0.id == Self.me }) else { throw CircleError.notFound }
        guard detail.circle.createdBy == Self.me else { throw CircleError.creatorOnly }
        guard memberID != Self.me, detail.members.contains(where: { $0.id == memberID }) else { throw CircleError.notFound }
        detail.members.removeAll { $0.id == memberID }
        detail.circle.memberCount = detail.members.count
        circlesByID[circleID] = detail
    }

    func putFind(_ find: FindPolicy.Find, sightingID: UUID, accessToken: String) async throws {
        findLog.append("put \(sightingID)")
        let circles = findCircles[sightingID] ?? order.filter { circlesByID[$0]?.members.contains { $0.id == Self.me } == true }
        findCircles[sightingID] = circles
        for circle in circles {
            var item = feedItem(find, sightingID: sightingID)
            // A card shared by hand there keeps its extras and its hidden place, as on the server.
            if let card = sharedCards[sightingID], card.circleIDs.contains(circle) {
                item.card = feedItems[circle]?.first { $0.id == item.id }?.card
                if !card.includePlace { item.place = nil }
            }
            feedItems[circle, default: []].removeAll { $0.id == item.id }
            feedItems[circle, default: []].append(item)
        }
    }

    func shareCard(_ card: FindPolicy.Card, sightingID: UUID, accessToken: String) async throws {
        let mine = Set(order.filter { circlesByID[$0]?.members.contains { $0.id == Self.me } == true })
        guard !card.circleIDs.isEmpty, card.circleIDs.allSatisfy(mine.contains) else { throw CircleError.notFound }
        if let key = card.photo?.key, photos[key] == nil { throw CircleError.rejected }
        findLog.append("card \(sightingID)")
        sharedCards[sightingID] = card
        let previous = findCircles[sightingID] ?? []
        findCircles[sightingID] = previous + card.circleIDs.filter { !previous.contains($0) }
        let extras = FeedItem.SharedCard(note: card.note, caption: card.caption, photo: card.photo.map { FeedItem.SharedCard.Photo(key: $0.key, url: nil) })
        for circle in findCircles[sightingID] ?? [] {
            let chosen = card.circleIDs.contains(circle)
            let existing = feedItems[circle]?.first { $0.id == "\(Self.me)/\(sightingID.uuidString.lowercased())" }
            var item = existing ?? feedItem(card.find, sightingID: sightingID)
            if chosen {
                item = feedItem(card.find, sightingID: sightingID)
                item.place = card.includePlace ? card.find.place : nil
                item.card = extras
            }
            feedItems[circle, default: []].removeAll { $0.id == item.id }
            feedItems[circle, default: []].append(item)
        }
    }

    func photoUpload(sightingID: UUID, accessToken: String) async throws -> PhotoUpload {
        let key = "photos/\(Self.me)/\(sightingID.uuidString.lowercased())/\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()).jpg"
        return PhotoUpload(key: key, uploadURL: URL(string: "https://bucket.invalid/")!, fields: ["key": key, "Content-Type": "image/jpeg"], expiresAt: now().addingTimeInterval(900))
    }

    func uploadPhoto(_ jpeg: Data, to upload: PhotoUpload) async throws {
        findLog.append("photo \(upload.key)")
        photos[upload.key] = jpeg
    }

    private func feedItem(_ find: FindPolicy.Find, sightingID: UUID) -> FeedItem {
        FeedItem(
            sightingID: sightingID.uuidString.lowercased(), speciesID: find.speciesID, scientificName: find.scientificName,
            commonName: find.commonName, method: find.method, place: find.place,
            foundAt: (try? Date(find.foundAt, strategy: .iso8601)) ?? now(), newPatch: find.newPatch, rarity: find.rarity,
            art: find.art.map { FeedItem.Art(kind: $0.kind, key: $0.key, url: nil) },
            owner: FeedItem.Owner(id: Self.me, displayName: Self.myName), circleFirst: false, isMine: true,
            edition: find.edition
        )
    }

    func deleteFind(sightingID: UUID, accessToken: String) async throws {
        findLog.append("delete \(sightingID)")
        let id = "\(Self.me)/\(sightingID.uuidString.lowercased())"
        for circle in findCircles[sightingID] ?? [] {
            feedItems[circle]?.removeAll { $0.id == id }
        }
        findCircles[sightingID] = nil
        if let key = sharedCards[sightingID]?.photo?.key { photos[key] = nil }
        sharedCards[sightingID] = nil
    }

    func feed(circleID: String, cursor: String?, accessToken: String) async throws -> FeedPage {
        _ = try await circle(id: circleID, accessToken: accessToken)
        if failingFeeds.contains(circleID) { throw CircleError.server(500) }
        let items = feedItems[circleID] ?? []
        // First for the Guild counts only what's shown to this reader.
        let shown = items.filter { !blockedIDs.contains($0.owner.id) }
        let firsts = Dictionary(grouping: shown, by: \.scientificName).compactMapValues { $0.min { ($0.foundAt, $0.id) < ($1.foundAt, $1.id) }?.id }
        let sorted = items
            .map { item in
                var item = item
                item.circleFirst = firsts[item.scientificName] == item.id
                item.reactions = counts(of: item.id)
                return item
            }
            .sorted { ($0.foundAt, $0.id) > ($1.foundAt, $1.id) }
        // A cursor is the key of the last find read, as the server's is (`finds.py`), so finds landing since don't shift it. A blocked
        // account's finds are left out after the page is cut, as there too: a page can be short, or empty, with a cursor still
        // leading on (issue #71).
        let rest = cursor.map { key in sorted.filter { Self.cursor(of: $0) < key } } ?? sorted
        let page = Array(rest.prefix(HTTPCircleClient.feedPageSize))
        let next = rest.count > page.count ? page.last.map(Self.cursor(of:)) : nil
        return FeedPage(items: page.filter { !blockedIDs.contains($0.owner.id) }, nextCursor: next)
    }

    /// Sorts as the feed does, by time then id, whatever the find.
    private static func cursor(of item: FeedItem) -> String {
        String(format: "%020.6f|%@", item.foundAt.timeIntervalSince1970, item.id)
    }

    func registerDevice(token: String, environment: PushEnvironment, accessToken: String) async throws {
        devices[token] = environment
        deviceLog.append("register \(token) \(environment.rawValue)")
    }

    func unregisterDevice(token: String, accessToken: String) async throws {
        devices[token] = nil
        deviceLog.append("unregister \(token)")
    }

    func mutes(accessToken: String) async throws -> Mutes {
        try await wire()
        return muted
    }

    func report(_ report: ReportDraft, accessToken: String) async throws {
        guard report.accountID != Self.me else { throw CircleError.ownAccount }
        guard let detail = circlesByID[report.circleID],
              detail.members.contains(where: { $0.id == Self.me }),
              detail.members.contains(where: { $0.id == report.accountID }) else { throw CircleError.notFound }
        guard reports.count < 20 else { throw CircleError.tooManyReports }
        reports.append(report)
    }

    func blocks(accessToken: String) async throws -> [BlockedAccount] {
        try await wire()
        return blockedIDs.map { id in BlockedAccount(id: id, displayName: name(of: id)) }
    }

    func setBlocked(_ blocked: Bool, accountID: String, accessToken: String) async throws {
        blockedIDs.removeAll { $0 == accountID }
        guard blocked else { return }
        guard accountID != Self.me else { throw CircleError.ownAccount }
        guard circlesByID.values.contains(where: { detail in
            detail.members.contains { $0.id == Self.me } && detail.members.contains { $0.id == accountID }
        }) else { throw CircleError.notFound }
        blockedIDs.append(accountID)
    }

    private func name(of id: String) -> String? {
        circlesByID.values.lazy.flatMap(\.members).first { $0.id == id }?.displayName
    }

    func setCircleMuted(_ muted: Bool, circleID: String, accessToken: String) async throws {
        if muted {
            _ = try await circle(id: circleID, accessToken: accessToken)
            self.muted.circles.insert(circleID)
        } else {
            self.muted.circles.remove(circleID)
        }
    }

    func setFriendMuted(_ muted: Bool, friendID: String, accessToken: String) async throws {
        if muted {
            guard friendID != Self.me, circlesByID.values.contains(where: { detail in
                detail.members.contains { $0.id == Self.me } && detail.members.contains { $0.id == friendID }
            }) else { throw CircleError.notFound }
            self.muted.friends.insert(friendID)
        } else {
            self.muted.friends.remove(friendID)
        }
    }

    func goals(circleID: String, accessToken: String) async throws -> [CircleGoal] {
        let detail = try await circle(id: circleID, accessToken: accessToken)
        let zone = TimeZone(identifier: detail.circle.timeZone) ?? .gmt
        ensureMonthly(detail.circle, zone: zone)
        let now = now()
        let rise = goalRisesBy * (goalReads[circleID] ?? 0)
        goalReads[circleID, default: 0] += 1
        let goals = (storedGoals[circleID] ?? []).map { progressed($0.goal, headStart: $0.headStart + rise, circle: detail.circle, now: now) }
        let thisMonth = Self.calendar(zone).dateInterval(of: .month, for: now)?.start
        let monthly = goals.filter { $0.kind == .monthly && $0.startsAt == thisMonth }
        let order: [CircleGoal.Status: Int] = [.active: 0, .upcoming: 1, .ended: 2]
        let custom = goals
            .filter { $0.kind == .custom && now.timeIntervalSince($0.endsAt) < 7 * 86_400 }
            .sorted { (order[$0.status]!, $0.endDate) < (order[$1.status]!, $1.endDate) }
        return monthly + custom
    }

    func createGoal(_ draft: GoalDraft, circleID: String, accessToken: String) async throws -> CircleGoal {
        let detail = try await circle(id: circleID, accessToken: accessToken)
        let zone = TimeZone(identifier: detail.circle.timeZone) ?? .gmt
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...40).contains(title.count), (1...999).contains(draft.target),
              let start = Self.day(draft.startDate, zone), let end = Self.day(draft.endDate, zone), start <= end,
              let ends = Self.calendar(zone).date(byAdding: .day, value: 1, to: end), ends > now()
        else { throw CircleError.rejected }
        let goal = CircleGoal(
            id: "fake-goal-\(nextID)", kind: .custom, title: title, target: draft.target, startDate: draft.startDate,
            endDate: draft.endDate, startsAt: start, endsAt: ends, progress: 0, status: .active, completedAt: nil,
            createdBy: FeedItem.Owner(id: Self.me, displayName: Self.myName), canDelete: true
        )
        nextID += 1
        storedGoals[circleID, default: []].append((goal, 0))
        return progressed(goal, headStart: 0, circle: detail.circle, now: now())
    }

    func deleteGoal(id: String, circleID: String, accessToken: String) async throws {
        let detail = try await circle(id: circleID, accessToken: accessToken)
        guard let stored = storedGoals[circleID]?.first(where: { $0.goal.id == id }) else { throw CircleError.notFound }
        guard stored.goal.kind == .custom, [stored.goal.createdBy?.id, detail.circle.createdBy].contains(Self.me) else {
            throw CircleError.goalNotYours
        }
        storedGoals[circleID]?.removeAll { $0.goal.id == id }
    }

    private func ensureMonthly(_ circle: CircleSummary, zone: TimeZone) {
        let calendar = Self.calendar(zone)
        guard let month = calendar.dateInterval(of: .month, for: now()),
              !(storedGoals[circle.id] ?? []).contains(where: { $0.goal.kind == .monthly && $0.goal.startsAt == month.start })
        else { return }
        let target: Int
        if let created = calendar.dateInterval(of: .month, for: circle.createdAt), created.start >= month.start {
            target = 10
        } else {
            let previous = calendar.date(byAdding: .month, value: -1, to: month.start)!
            target = max(5, (species(in: circle.id, from: previous, to: month.start) * 115 + 50) / 100)
        }
        let days = GoalDraft.dayFormatter(zone)
        let goal = CircleGoal(
            id: "monthly-\(days.string(from: month.start).prefix(7))", kind: .monthly,
            title: "\(month.start.formatted(Date.FormatStyle(timeZone: zone).month(.wide))) goal", target: target,
            startDate: days.string(from: month.start), endDate: days.string(from: month.end.addingTimeInterval(-1)),
            startsAt: month.start, endsAt: month.end, progress: 0, status: .active, completedAt: nil, createdBy: nil,
            canDelete: false
        )
        storedGoals[circle.id, default: []].append((goal, 0))
    }

    private func progressed(_ goal: CircleGoal, headStart: Int, circle: CircleSummary, now: Date) -> CircleGoal {
        var goal = goal
        goal.progress = headStart + species(in: circle.id, from: goal.startsAt, to: goal.endsAt)
        goal.species = counted(in: circle.id, from: goal.startsAt, to: goal.endsAt, headStart: headStart)
        goal.status = now < goal.startsAt ? .upcoming : now < goal.endsAt ? .active : .ended
        goal.canDelete = goal.kind == .custom && [goal.createdBy?.id, circle.createdBy].contains(Self.me)
        if goal.isReached, goal.completedAt == nil { goal.completedAt = now }
        return goal
    }

    private func species(in circleID: String, from start: Date, to end: Date) -> Int {
        Set((feedItems[circleID] ?? []).filter { $0.foundAt >= start && $0.foundAt < end }.map(\.scientificName)).count
    }

    /// What progress counted, earliest found first, with an edition each, as the server says: the head start's birds, which stand
    /// in for finds older than the feed shows, then the feed's.
    private func counted(in circleID: String, from start: Date, to end: Date, headStart: Int) -> [CircleGoal.Species] {
        var found: [String: FeedItem] = [:]
        var editions: [String: String] = [:]
        for item in (feedItems[circleID] ?? []).filter({ $0.foundAt >= start && $0.foundAt < end }).sorted(by: { $0.foundAt < $1.foundAt }) {
            if found[item.scientificName] == nil { found[item.scientificName] = item }
            if editions[item.scientificName] == nil { editions[item.scientificName] = item.edition }
        }
        let early = Self.goalBirds
            .filter { found[Sighting.scientificName(ofLabel: $0)] == nil }
            .prefix(max(0, headStart))
            .map { CircleGoal.Species(speciesID: $0, scientificName: Sighting.scientificName(ofLabel: $0), commonName: BirdComparison.commonName(ofLabel: $0), edition: "us-ca-la") }
        let feed = found.values.sorted { $0.foundAt < $1.foundAt }.map {
            CircleGoal.Species(speciesID: $0.speciesID, scientificName: $0.scientificName, commonName: $0.commonName, edition: editions[$0.scientificName])
        }
        return early + feed
    }

    /// Los Angeles birds for a seeded goal's head start, the last of them newest as the reference's row runs.
    private static let goalBirds = [
        "Buteo jamaicensis_Red-tailed Hawk", "Anas platyrhynchos_Mallard", "Melozone crissalis_California Towhee", "Spinus psaltria_Lesser Goldfinch",
        "Mimus polyglottos_Northern Mockingbird", "Branta canadensis_Canada Goose", "Ardea alba_Great Egret", "Callipepla californica_California Quail",
        "Sialia mexicana_Western Bluebird", "Zenaida macroura_Mourning Dove", "Melospiza melodia_Song Sparrow", "Corvus brachyrhynchos_American Crow",
        "Pipilo maculatus_Spotted Towhee", "Ardea herodias_Great Blue Heron", "Bubo virginianus_Great Horned Owl", "Cathartes aura_Turkey Vulture",
        "Junco hyemalis_Dark-eyed Junco", "Passer domesticus_House Sparrow", "Larus occidentalis_Western Gull", "Columba livia_Rock Dove",
        "Fulica americana_American Coot", "Corvus corax_Northern Raven", "Egretta thula_Snowy Egret", "Buteo lineatus_Red-shouldered Hawk",
        "Astur cooperii_Cooper's Hawk", "Selasphorus sasin_Allen's Hummingbird", "Psaltriparus minimus_American Bushtit", "Tyrannus vociferans_Cassin's Kingbird",
        "Icterus cucullatus_Hooded Oriole", "Dryobates nuttallii_Nuttall's Woodpecker",
    ]

    private static func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    private static func day(_ text: String, _ zone: TimeZone) -> Date? { GoalDraft.dayFormatter(zone).date(from: text) }

    /// Sunday Group's goals: the month's, a running custom goal, an upcoming Big Day, and one reached last week.
    private func seedGoals(circleID: String) {
        guard let circle = circlesByID[circleID]?.circle, let zone = TimeZone(identifier: circle.timeZone) else { return }
        let calendar = Self.calendar(zone)
        let days = GoalDraft.dayFormatter(zone)
        let today = calendar.startOfDay(for: now())
        func custom(_ title: String, _ target: Int, from start: Int, to end: Int, by owner: (String, String), headStart: Int) {
            let first = calendar.date(byAdding: .day, value: start, to: today)!
            let last = calendar.date(byAdding: .day, value: end, to: today)!
            let goal = CircleGoal(
                id: "fake-goal-\(nextID)", kind: .custom, title: title, target: target, startDate: days.string(from: first),
                endDate: days.string(from: last), startsAt: first, endsAt: calendar.date(byAdding: .day, value: 1, to: last)!,
                progress: 0, status: .active, completedAt: nil, createdBy: FeedItem.Owner(id: owner.0, displayName: owner.1),
                canDelete: false
            )
            nextID += 1
            storedGoals[circleID, default: []].append((goal, headStart))
        }
        ensureMonthly(circle, zone: zone)
        if var monthly = storedGoals[circleID]?.first {
            monthly.goal.target = 14
            // 9 of 14 whatever the date: the seeded finds are days old, so how many fall in this month changes as it goes on. A plain
            // head start of 9 reached the target once all five species were in the month, about six days in.
            monthly.headStart = 9 - species(in: circleID, from: monthly.goal.startsAt, to: monthly.goal.endsAt)
            storedGoals[circleID] = [monthly]
        }
        custom("Fall migration", 30, from: -20, to: 9, by: ("maya", "Maya Ortiz"), headStart: 19)
        custom("Big Day in Ojai", 40, from: 5, to: 5, by: (Self.me, Self.myName), headStart: 0)
        custom("Owls before Halloween", 3, from: -12, to: -3, by: ("jo", "Jo Park"), headStart: 3)
    }

    func setReaction(_ kind: ReactionKind, given: Bool, owner: String, sightingID: String, accessToken: String) async throws -> [ReactionCount] {
        if reactionsFail { throw CircleError.server(500) }
        let id = "\(owner)/\(sightingID)"
        let mine = Set(order.filter { circlesByID[$0]?.members.contains { $0.id == Self.me } == true })
        guard owner != Self.me else { throw CircleError.rejected }
        guard feedItems.contains(where: { mine.contains($0.key) && $0.value.contains { $0.id == id } }) else { throw CircleError.notFound }
        reactionLog.append("\(given ? "put" : "delete") \(kind.rawValue) \(id)")
        if given {
            reactions[id, default: [:]][kind, default: []].insert(Self.me)
        } else {
            reactions[id]?[kind]?.remove(Self.me)
        }
        return counts(of: id)
    }

    func compare(friendID: String, accessToken: String) async throws -> FriendBirds {
        compareLog.append(friendID)
        try await wire()
        let shared = order.filter { id in
            let members = circlesByID[id]?.members ?? []
            return members.contains { $0.id == Self.me } && members.contains { $0.id == friendID }
        }
        guard friendID != Self.me, !shared.isEmpty, !blockedIDs.contains(friendID) else { throw CircleError.notFound }
        var best: [String: FriendBirds.Species] = [:]
        var editions: [String: [String]] = [:]
        // Earliest found first, so the first edition is the patch to show, as on the server.
        for item in shared.flatMap({ feedItems[$0] ?? [] }).filter({ $0.owner.id == friendID }).sorted(by: { $0.foundAt < $1.foundAt }) {
            if best[item.scientificName]?.method != .seen {
                best[item.scientificName] = .init(speciesID: item.speciesID, scientificName: item.scientificName, commonName: item.commonName, method: item.method)
            }
            if let edition = item.edition, editions[item.scientificName]?.contains(edition) != true {
                editions[item.scientificName, default: []].append(edition)
            }
        }
        for name in best.keys { best[name]?.editions = editions[name] ?? [] }
        for species in moreCompared[friendID] ?? [] { best[species.scientificName] = species }
        let name = shared.lazy.compactMap { self.circlesByID[$0]?.members.first { $0.id == friendID }?.displayName }.first
        let birds = FriendBirds(friend: .init(id: friendID, displayName: name), species: best.values.sorted { $0.commonName < $1.commonName })
        if compareAnswerLatency > .zero { try? await Task.sleep(for: compareAnswerLatency) }
        return birds
    }

    private func counts(of itemID: String) -> [ReactionCount] {
        let given = reactions[itemID] ?? [:]
        return ReactionKind.allCases.map { ReactionCount(kind: $0, count: given[$0]?.count ?? 0, mine: given[$0]?.contains(Self.me) ?? false) }
    }

    /// Friends' finds in a seeded circle: a circle first, new patches, a repeat, a rare bird and one at a secret spot, and two
    /// older ones of Maya's for Compare birds. Jo and Sam already find Maya's Black Phoebe lovely, and Maya is
    /// jealous of Sam's Gnatcatcher.
    private func seedFeed(circleID: String) {
        let finds: [(String, String, String, SightingMethod, String?, RarityLabel?, Bool, String, Double)] = [
            ("maya", "Maya Ortiz", "Sayornis nigricans_Black Phoebe", .seen, "Pasadena", .common, true, "sayornis-nigricans", 3),
            ("jo", "Jo Park", "Calypte anna_Anna's Hummingbird", .heard, nil, .common, false, "calypte-anna", 2),
            ("jo", "Jo Park", "Sayornis nigricans_Black Phoebe", .heard, "Pasadena", .common, false, "sayornis-nigricans", 1.5),
            ("sam", "Sam Okafor", "Polioptila californica_California Gnatcatcher", .heard, FindPolicy.secretSpot, .rare, false, "polioptila-californica", 1),
            ("maya", "Maya Ortiz", "Melanerpes formicivorus_Acorn Woodpecker", .heard, "Altadena", .common, true, "melanerpes-formicivorus", 5),
            ("maya", "Maya Ortiz", "Haemorhous mexicanus_House Finch", .seen, "Pasadena", .common, true, "haemorhous-mexicanus", 6),
        ]
        reactions["maya/00000000-0000-4000-8000-000000000000"] = [.lovely: ["jo", "sam"], .together: ["jo"]]
        reactions["sam/00000000-0000-4000-8000-000000000003"] = [.jealous: ["maya"]]
        for (index, (owner, name, label, method, place, rarity, newPatch, art, daysAgo)) in finds.enumerated() {
            let common = String(label.split(separator: "_", maxSplits: 1).last ?? "")
            feedItems[circleID, default: []].append(FeedItem(
                sightingID: "00000000-0000-4000-8000-00000000000\(index)", speciesID: label,
                scientificName: Sighting.scientificName(ofLabel: label), commonName: common, method: method, place: place,
                foundAt: now().addingTimeInterval(-daysAgo * 86_400), newPatch: newPatch, rarity: rarity,
                art: FeedItem.Art(kind: "pack", key: "packs/us-ca-la/\(art).jpg", url: nil),
                owner: FeedItem.Owner(id: owner, displayName: name), circleFirst: false, isMine: false,
                // Jo shared the hummingbird by hand (issue #66), with the caption and a note, and left the city out.
                card: index == 1 ? FeedItem.SharedCard(note: "Buzzing the sage by the gate, twice.", caption: "A green spark hums where the sage is in flower.", photo: nil) : nil,
                edition: "us-ca-la"
            ))
        }
    }

    /// Someone in a Guild with Pat, for the tests.
    func addMember(_ id: String, to circleID: String) {
        guard var detail = circlesByID[circleID], !detail.members.contains(where: { $0.id == id }) else { return }
        detail.members.append(CircleMember(id: id, displayName: id, joinedAt: now(), isCreator: false))
        detail.circle.memberCount = detail.members.count
        circlesByID[circleID] = detail
    }

    /// Finds landing in the first Guild, by Maya, newest first: what a push would be about.
    func addLateFinds(_ count: Int) {
        guard let circle = order.first(where: { circlesByID[$0]?.members.contains { $0.id == Self.me } == true }) else { return }
        for index in 0..<count {
            add(seededFind(
                sighting: "late-\(index)", owner: ("maya", "Maya Ortiz"), label: "Sayornis nigricans_Black Phoebe", method: .seen, place: "Pasadena",
                rarity: .common, newPatch: true, edition: "us-ca-la", daysAgo: Double(index) / 86_400
            ), to: circle)
        }
    }

    /// A friend's find gone from a Guild, as when they remove the sighting, for the tests.
    func deleteFriendFind(_ itemID: String, circleID: String) async throws {
        feedItems[circleID]?.removeAll { $0.id == itemID }
    }

    /// A find already in a Guild, for the tests.
    func add(_ item: FeedItem, to circleID: String) {
        feedItems[circleID, default: []].append(item)
    }

    /// What a friend has beyond the feed, for the tests.
    func setMoreCompared(_ species: [FriendBirds.Species], friendID: String) {
        moreCompared[friendID] = species
    }

    /// `-fakeCircles one`: Pat in the one Guild, with Sunday Group's feed and goals, so the tab opens straight on it.
    func seedOneGuild() {
        let id = add(name: "Sunday Group", creator: (Self.me, Self.myName), others: [("maya", "Maya Ortiz"), ("jo", "Jo Park"), ("sam", "Sam Okafor")], at: Date(timeIntervalSince1970: 1_790_000_000))
        seedFeed(circleID: id)
        seedGoals(circleID: id)
    }

    /// `-fakeCircles shared`, on top of the seeds (issue #150): Family gets a feed too. Jo joins it, her hummingbird is in both
    /// Guilds, Lee has a run of repeats and two patches from an edition the phone doesn't have, one of a bird no pack on the
    /// phone describes. A find's First for the Guild goes to the earliest of its species, so the repeats have older finds.
    func seedSharedFinds() {
        guard let family = order.first(where: { circlesByID[$0]?.circle.name == "Family" }),
              let sunday = order.first(where: { circlesByID[$0]?.circle.name == "Sunday Group" }),
              var detail = circlesByID[family] else { return }
        detail.members.append(CircleMember(id: "jo", displayName: "Jo Park", joinedAt: detail.circle.createdAt, isCreator: false))
        detail.circle.memberCount = detail.members.count
        circlesByID[family] = detail
        if let hummingbird = feedItems[sunday]?.first(where: { $0.sightingID == Self.sharedSighting }) {
            feedItems[family, default: []].append(hummingbird)
        }
        let finds: [(String, String, String, SightingMethod, Bool, String, Double)] = [
            ("10", "Haemorhous mexicanus_House Finch", "Altadena", .heard, false, "us-ca-la", 0.1),
            ("11", "Zenaida macroura_Mourning Dove", "Altadena", .seen, false, "us-ca-la", 0.2),
            ("12", "Haemorhous mexicanus_House Finch", "Altadena", .seen, false, "us-ca-la", 0.3),
            ("13", "Sayornis nigricans_Black Phoebe", "Ocean Beach", .seen, true, "us-ca-sd", 2.5),
            ("14", "Puffinus opisthomelas_Black-vented Shearwater", "Ocean Beach", .seen, true, "us-ca-sd", 2.6),
            ("15", "Haemorhous mexicanus_House Finch", "Altadena", .seen, true, "us-ca-la", 9),
            ("16", "Zenaida macroura_Mourning Dove", "Altadena", .seen, true, "us-ca-la", 10),
        ]
        for (suffix, label, place, method, newPatch, edition, daysAgo) in finds {
            feedItems[family, default: []].append(seededFind(
                sighting: "00000000-0000-4000-8000-0000000000\(suffix)", owner: ("lee", "Lee Birder"), label: label, method: method, place: place,
                rarity: .common, newPatch: newPatch, edition: edition, daysAgo: daysAgo
            ))
        }
    }

    /// `-fakeCircles reference`: Sunday Group as the reference picture draws it, for the side-by-side (issue #150). Pat already
    /// finds Maya's phoebe lovely, and the goal stands at 12 of 14.
    func seedReference() {
        guard let sunday = order.first(where: { circlesByID[$0]?.circle.name == "Sunday Group" }) else { return }
        let maya = "00000000-0000-4000-8000-000000000020"
        let jo = "00000000-0000-4000-8000-000000000021"
        feedItems[sunday] = [
            seededFind(sighting: maya, owner: ("maya", "Maya Ortiz"), label: "Sayornis nigricans_Black Phoebe", method: .seen, place: "Pasadena", rarity: .common, newPatch: true, edition: "us-ca-la", daysAgo: 3),
            seededFind(sighting: jo, owner: ("jo", "Jo Park"), label: "Calypte anna_Anna's Hummingbird", method: .heard, place: "Altadena", rarity: .common, newPatch: true, edition: "us-ca-la", daysAgo: 4),
            // Older, so Jo's hummingbird isn't the Guild's first.
            seededFind(sighting: "00000000-0000-4000-8000-000000000022", owner: ("sam", "Sam Okafor"), label: "Calypte anna_Anna's Hummingbird", method: .seen, place: "Pasadena", rarity: .common, newPatch: true, edition: "us-ca-la", daysAgo: 9),
        ]
        reactions = ["maya/\(maya)": [.lovely: ["jo", Self.me]], "jo/\(jo)": [.jealous: ["maya"]]]
        if var goals = storedGoals[sunday], !goals.isEmpty {
            goals[0].headStart = 12 - species(in: sunday, from: goals[0].goal.startsAt, to: goals[0].goal.endsAt)
            storedGoals[sunday] = goals
        }
        // Compare as the reference draws it, and friends' faces near the top of Los Angeles.
        moreCompared = [
            "maya": [
                compared("Melanerpes formicivorus_Acorn Woodpecker", .heard), compared("Sialia mexicana_Western Bluebird", .seen),
                compared("Ardea alba_Great Egret", .seen), compared("Haemorhous mexicanus_House Finch", .seen),
            ],
            "jo": [compared("Branta canadensis_Canada Goose", .seen), compared("Alopochen aegyptiaca_Egyptian Goose", .seen), compared("Cairina moschata_Muscovy Duck", .heard)],
            "sam": [compared("Cairina moschata_Muscovy Duck", .seen)],
        ]
    }

    private func compared(_ label: String, _ method: SightingMethod) -> FriendBirds.Species {
        .init(speciesID: label, scientificName: Sighting.scientificName(ofLabel: label), commonName: BirdComparison.commonName(ofLabel: label), method: method, editions: ["us-ca-la"])
    }

    /// Jo's hummingbird (issue #66), the one shared by hand.
    private static let sharedSighting = "00000000-0000-4000-8000-000000000001"

    private func seededFind(sighting: String, owner: (String, String), label: String, method: SightingMethod, place: String?, rarity: RarityLabel, newPatch: Bool, edition: String, daysAgo: Double) -> FeedItem {
        FeedItem(
            sightingID: sighting, speciesID: label, scientificName: Sighting.scientificName(ofLabel: label),
            commonName: String(label.split(separator: "_", maxSplits: 1).last ?? ""), method: method, place: place,
            foundAt: now().addingTimeInterval(-daysAgo * 86_400), newPatch: newPatch, rarity: rarity, art: nil,
            owner: FeedItem.Owner(id: owner.0, displayName: owner.1), circleFirst: false, isMine: false, edition: edition
        )
    }

    @discardableResult
    private func add(name: String, creator: (String, String), others: [(String, String)], at date: Date, timeZone: String = "America/Los_Angeles") -> String {
        let id = "fake-circle-\(nextID)"
        nextID += 1
        let members = [CircleMember(id: creator.0, displayName: creator.1, joinedAt: date, isCreator: true)]
            + others.enumerated().map { CircleMember(id: $1.0, displayName: $1.1, joinedAt: date.addingTimeInterval(Double($0 + 1) * 3600), isCreator: false) }
        let circle = CircleSummary(id: id, name: name, createdBy: creator.0, createdAt: date, timeZone: timeZone, memberCount: members.count, isCreator: false)
        circlesByID[id] = CircleDetail(circle: circle, members: members)
        order.append(id)
        return id
    }

    private func live(_ token: String) throws -> (CircleDetail, Date) {
        guard let invite = invites[token], let detail = circlesByID[invite.circleID] else { throw CircleError.notFound }
        guard now() < invite.expiresAt else { throw CircleError.inviteExpired }
        return (detail, invite.expiresAt)
    }

    private func summary(_ detail: CircleDetail) -> CircleSummary { withViewer(detail).circle }

    private func withViewer(_ detail: CircleDetail) -> CircleDetail {
        var detail = detail
        detail.circle.isCreator = detail.circle.createdBy == Self.me
        return detail
    }
}
#endif

