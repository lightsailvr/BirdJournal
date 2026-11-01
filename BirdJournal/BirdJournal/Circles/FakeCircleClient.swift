#if DEBUG
import Foundation

/// The debug fake circle server (`-fakeCircles empty|some`, issue #61): circles, members and invites in memory, with
/// the backend's rules (20 members, seven-day invites, the creator removes). The fake account is "Pat Birder"
/// (`fake-sub`). Invite tokens it knows besides its own: `fake-invite` (Canyon Walkers, from Maya), `expired` and
/// `full`. Nothing leaves the phone.
final class FakeCircleClient: CircleClient {
    static let me = "fake-sub"
    static let myName = "Pat Birder"
    private var circlesByID: [String: CircleDetail] = [:]
    private var order: [String] = []
    private var invites: [String: (circleID: String, expiresAt: Date)] = [:]
    private var nextID = 1
    private let now: () -> Date

    init(seeded: Bool, now: @escaping () -> Date = Date.init) {
        self.now = now
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        if seeded {
            add(name: "Sunday Group", creator: (Self.me, Self.myName), others: [("maya", "Maya Ortiz"), ("jo", "Jo Park"), ("sam", "Sam Okafor")], at: base)
            add(name: "Family", creator: ("dad", "Robin Birder"), others: [(Self.me, Self.myName), ("lee", "Lee Birder")], at: base.addingTimeInterval(86_400))
        }
        let canyon = add(name: "Canyon Walkers", creator: ("maya", "Maya Ortiz"), others: [("ari", "Ari Chen")], at: base)
        invites["fake-invite"] = (canyon, .distantFuture)
        invites["expired"] = (canyon, .distantPast)
        let full = add(name: "Big Year Crew", creator: ("maya", "Maya Ortiz"), others: (2...20).map { ("m\($0)", "Member \($0)") }, at: base)
        invites["full"] = (full, .distantFuture)
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
