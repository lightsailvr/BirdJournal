#if DEBUG
import Album
import Foundation

/// The debug fake circle server (`-fakeCircles empty|some`, issue #61): circles, members and invites in memory, with
/// the backend's rules (20 members, seven-day invites, the creator removes). The fake account is "Pat Birder"
/// (`fake-sub`). Invite tokens it knows besides its own: `fake-invite` (Canyon Walkers, from Maya), `expired` and
/// `full`. Finds (issue #62) fan out to the circles Pat is in when first put, as on the server; seeded, Sunday Group's
/// feed has friends' finds. Goals (issue #65) follow the server's rules: a monthly goal per circle in its time zone
/// (10 in the first month, else the larger of 5 and 115 % of last month's species), progress as distinct species among
/// the feed's finds in the period, custom goals deleted by their creator or the circle's. Seeded, Sunday Group chases
/// its monthly goal, a running and an upcoming custom goal, and one reached last week. Nothing leaves the phone.
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
    /// Every circle's goals without their progress, which is counted from the feed when read. `head start` stands in
    /// for seeded finds older than the feed shows, so the seeded goals aren't all at zero.
    private var storedGoals: [String: [(goal: CircleGoal, headStart: Int)]] = [:]

    init(seeded: Bool, now: @escaping () -> Date = Date.init) {
        self.now = now
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
        order.compactMap { circlesByID[$0] }.filter { $0.members.contains { $0.id == Self.me } }.map { summary($0) }
    }

    func createCircle(named name: String, timeZone: String, accessToken: String) async throws -> CircleDetail {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...40).contains(trimmed.count) else { throw CircleError.rejected }
        let id = add(name: trimmed, creator: (Self.me, Self.myName), others: [], at: now(), timeZone: timeZone)
        return try await circle(id: id, accessToken: accessToken)
    }

    func circle(id: String, accessToken: String) async throws -> CircleDetail {
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
            foundAt: (try? Date(find.foundAt, strategy: .iso8601)) ?? now(), legendary: find.legendary, rarity: find.rarity,
            art: find.art.map { FeedItem.Art(kind: $0.kind, key: $0.key, url: nil) },
            owner: FeedItem.Owner(id: Self.me, displayName: Self.myName), circleFirst: false, isMine: true
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
        let items = feedItems[circleID] ?? []
        let firsts = Dictionary(grouping: items, by: \.scientificName).compactMapValues { $0.min { ($0.foundAt, $0.id) < ($1.foundAt, $1.id) }?.id }
        let sorted = items
            .map { item in var item = item; item.circleFirst = firsts[item.scientificName] == item.id; return item }
            .sorted { ($0.foundAt, $0.id) > ($1.foundAt, $1.id) }
        let start = cursor.flatMap(Int.init) ?? 0
        let page = Array(sorted.dropFirst(start).prefix(HTTPCircleClient.feedPageSize))
        let next = start + page.count < sorted.count ? String(start + page.count) : nil
        return FeedPage(items: page, nextCursor: next)
    }

    func registerDevice(token: String, environment: PushEnvironment, accessToken: String) async throws {
        devices[token] = environment
        deviceLog.append("register \(token) \(environment.rawValue)")
    }

    func unregisterDevice(token: String, accessToken: String) async throws {
        devices[token] = nil
        deviceLog.append("unregister \(token)")
    }

    func mutes(accessToken: String) async throws -> Mutes { muted }

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
        let goals = (storedGoals[circleID] ?? []).map { progressed($0.goal, headStart: $0.headStart, circle: detail.circle, now: now) }
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
        goal.status = now < goal.startsAt ? .upcoming : now < goal.endsAt ? .active : .ended
        goal.canDelete = goal.kind == .custom && [goal.createdBy?.id, circle.createdBy].contains(Self.me)
        if goal.isReached, goal.completedAt == nil { goal.completedAt = now }
        return goal
    }

    private func species(in circleID: String, from start: Date, to end: Date) -> Int {
        Set((feedItems[circleID] ?? []).filter { $0.foundAt >= start && $0.foundAt < end }.map(\.scientificName)).count
    }

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
            monthly.headStart = 9
            storedGoals[circleID] = [monthly]
        }
        custom("Fall migration", 30, from: -20, to: 9, by: ("maya", "Maya Ortiz"), headStart: 19)
        custom("Big Day in Ojai", 40, from: 5, to: 5, by: (Self.me, Self.myName), headStart: 0)
        custom("Owls before Halloween", 3, from: -12, to: -3, by: ("jo", "Jo Park"), headStart: 3)
    }

    /// Friends' finds in a seeded circle: a circle first, a Legendary, a rare bird and one at a secret spot.
    private func seedFeed(circleID: String) {
        let finds: [(String, String, String, SightingMethod, String?, RarityLabel?, Bool, String, Double)] = [
            ("maya", "Maya Ortiz", "Sayornis nigricans_Black Phoebe", .seen, "Pasadena", .common, true, "sayornis-nigricans", 3),
            ("jo", "Jo Park", "Calypte anna_Anna's Hummingbird", .heard, nil, .common, false, "calypte-anna", 2),
            ("jo", "Jo Park", "Sayornis nigricans_Black Phoebe", .heard, "Pasadena", .common, false, "sayornis-nigricans", 1.5),
            ("sam", "Sam Okafor", "Polioptila californica_California Gnatcatcher", .heard, FindPolicy.secretSpot, .rare, false, "polioptila-californica", 1),
        ]
        for (index, (owner, name, label, method, place, rarity, legendary, art, daysAgo)) in finds.enumerated() {
            let common = String(label.split(separator: "_", maxSplits: 1).last ?? "")
            feedItems[circleID, default: []].append(FeedItem(
                sightingID: "00000000-0000-4000-8000-00000000000\(index)", speciesID: label,
                scientificName: Sighting.scientificName(ofLabel: label), commonName: common, method: method, place: place,
                foundAt: now().addingTimeInterval(-daysAgo * 86_400), legendary: legendary, rarity: rarity,
                art: FeedItem.Art(kind: "pack", key: "packs/us-ca-la/\(art).jpg", url: nil),
                owner: FeedItem.Owner(id: owner, displayName: name), circleFirst: false, isMine: false,
                // Jo shared the hummingbird by hand (issue #66), with the caption and a note, and left the city out.
                card: index == 1 ? FeedItem.SharedCard(note: "Buzzing the sage by the gate, twice.", caption: "A green spark hums where the sage is in flower.", photo: nil) : nil
            ))
        }
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

