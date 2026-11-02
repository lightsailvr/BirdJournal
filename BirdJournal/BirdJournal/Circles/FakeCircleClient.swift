#if DEBUG
import Album
import Foundation

/// The debug fake circle server (`-fakeCircles empty|some`, issue #61): circles, members and invites in memory, with
/// the backend's rules (20 members, seven-day invites, the creator removes). The fake account is "Pat Birder"
/// (`fake-sub`). Invite tokens it knows besides its own: `fake-invite` (Canyon Walkers, from Maya), `expired` and
/// `full`. Finds (issue #62) fan out to the circles Pat is in when first put, as on the server; seeded, Sunday Group's
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
    /// Every put and delete, for the tests: `put <id>` or `delete <id>`.
    private(set) var findLog: [String] = []
    /// The phone tokens registered to Pat (issue #63), with their environment.
    private(set) var devices: [String: PushEnvironment] = [:]
    /// Every device registration and removal, for the tests: `register <token> <environment>` or `unregister <token>`.
    private(set) var deviceLog: [String] = []
    private var muted = Mutes()
    /// Who gave each reaction, by feed item id.
    private var reactions: [String: [ReactionKind: Set<String>]] = [:]
    /// Every reaction given or taken back, for the tests: `put lovely maya/<id>` or `delete …`.
    private(set) var reactionLog: [String] = []

    init(seeded: Bool, now: @escaping () -> Date = Date.init) {
        self.now = now
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        if seeded {
            add(name: "Sunday Group", creator: (Self.me, Self.myName), others: [("maya", "Maya Ortiz"), ("jo", "Jo Park"), ("sam", "Sam Okafor")], at: base)
            add(name: "Family", creator: ("dad", "Robin Birder"), others: [(Self.me, Self.myName), ("lee", "Lee Birder")], at: base.addingTimeInterval(86_400))
        }
        if seeded, let sunday = order.first {
            seedFeed(circleID: sunday)
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
        let item = FeedItem(
            sightingID: sightingID.uuidString.lowercased(), speciesID: find.speciesID, scientificName: find.scientificName,
            commonName: find.commonName, method: find.method, place: find.place,
            foundAt: (try? Date(find.foundAt, strategy: .iso8601)) ?? now(), legendary: find.legendary, rarity: find.rarity,
            art: find.art.map { FeedItem.Art(kind: $0.kind, key: $0.key, url: nil) },
            owner: FeedItem.Owner(id: Self.me, displayName: Self.myName), circleFirst: false, isMine: true
        )
        for circle in circles {
            feedItems[circle, default: []].removeAll { $0.id == item.id }
            feedItems[circle, default: []].append(item)
        }
    }

    func deleteFind(sightingID: UUID, accessToken: String) async throws {
        findLog.append("delete \(sightingID)")
        let id = "\(Self.me)/\(sightingID.uuidString.lowercased())"
        for circle in findCircles[sightingID] ?? [] {
            feedItems[circle]?.removeAll { $0.id == id }
        }
        findCircles[sightingID] = nil
    }

    func feed(circleID: String, cursor: String?, accessToken: String) async throws -> FeedPage {
        _ = try await circle(id: circleID, accessToken: accessToken)
        let items = feedItems[circleID] ?? []
        let firsts = Dictionary(grouping: items, by: \.scientificName).compactMapValues { $0.min { ($0.foundAt, $0.id) < ($1.foundAt, $1.id) }?.id }
        let sorted = items
            .map { item in
                var item = item
                item.circleFirst = firsts[item.scientificName] == item.id
                item.reactions = counts(of: item.id)
                return item
            }
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

    func setReaction(_ kind: ReactionKind, given: Bool, owner: String, sightingID: String, accessToken: String) async throws -> [ReactionCount] {
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
        let shared = order.filter { id in
            let members = circlesByID[id]?.members ?? []
            return members.contains { $0.id == Self.me } && members.contains { $0.id == friendID }
        }
        guard friendID != Self.me, !shared.isEmpty else { throw CircleError.notFound }
        var best: [String: FriendBirds.Species] = [:]
        for item in shared.flatMap({ feedItems[$0] ?? [] }) where item.owner.id == friendID {
            if best[item.scientificName]?.method != .seen {
                best[item.scientificName] = .init(speciesID: item.speciesID, scientificName: item.scientificName, commonName: item.commonName, method: item.method)
            }
        }
        let name = shared.lazy.compactMap { self.circlesByID[$0]?.members.first { $0.id == friendID }?.displayName }.first
        return FriendBirds(friend: .init(id: friendID, displayName: name), species: best.values.sorted { $0.commonName < $1.commonName })
    }

    private func counts(of itemID: String) -> [ReactionCount] {
        let given = reactions[itemID] ?? [:]
        return ReactionKind.allCases.map { ReactionCount(kind: $0, count: given[$0]?.count ?? 0, mine: given[$0]?.contains(Self.me) ?? false) }
    }

    /// Friends' finds in a seeded circle: a circle first, a Legendary, a rare bird and one at a secret spot, and two
    /// older ones of Maya's for Compare birds. Jo and Sam already find Maya's Black Phoebe lovely, and Maya is
    /// jealous of Sam's Gnatcatcher.
    private func seedFeed(circleID: String) {
        let finds: [(String, String, String, SightingMethod, String?, RarityLabel?, Bool, String, Double)] = [
            ("maya", "Maya Ortiz", "Sayornis nigricans_Black Phoebe", .seen, "Pasadena", .common, true, "sayornis-nigricans", 3),
            ("jo", "Jo Park", "Calypte anna_Anna's Hummingbird", .heard, "Altadena", .common, false, "calypte-anna", 2),
            ("jo", "Jo Park", "Sayornis nigricans_Black Phoebe", .heard, "Pasadena", .common, false, "sayornis-nigricans", 1.5),
            ("sam", "Sam Okafor", "Polioptila californica_California Gnatcatcher", .heard, FindPolicy.secretSpot, .rare, false, "polioptila-californica", 1),
            ("maya", "Maya Ortiz", "Melanerpes formicivorus_Acorn Woodpecker", .heard, "Altadena", .common, true, "melanerpes-formicivorus", 5),
            ("maya", "Maya Ortiz", "Haemorhous mexicanus_House Finch", .seen, "Pasadena", .common, true, "haemorhous-mexicanus", 6),
        ]
        reactions["maya/00000000-0000-4000-8000-000000000000"] = [.lovely: ["jo", "sam"], .together: ["jo"]]
        reactions["sam/00000000-0000-4000-8000-000000000003"] = [.jealous: ["maya"]]
        for (index, (owner, name, label, method, place, rarity, legendary, art, daysAgo)) in finds.enumerated() {
            let common = String(label.split(separator: "_", maxSplits: 1).last ?? "")
            feedItems[circleID, default: []].append(FeedItem(
                sightingID: "00000000-0000-4000-8000-00000000000\(index)", speciesID: label,
                scientificName: Sighting.scientificName(ofLabel: label), commonName: common, method: method, place: place,
                foundAt: now().addingTimeInterval(-daysAgo * 86_400), legendary: legendary, rarity: rarity,
                art: FeedItem.Art(kind: "pack", key: "packs/us-ca-la/\(art).jpg", url: nil),
                owner: FeedItem.Owner(id: owner, displayName: name), circleFirst: false, isMine: false
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
