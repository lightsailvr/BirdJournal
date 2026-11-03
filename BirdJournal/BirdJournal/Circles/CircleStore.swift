import Foundation
import Observation
import OSLog

/// The birder's circles (issue #61) over a `CircleClient`, with the account's token. The Circles tab, a circle's page
/// and the join screen read it. An invite link that arrives while the app runs (or launches it) waits in
/// `pendingInvite` until the join screen takes it.
@Observable
final class CircleStore {
    struct Feed: Equatable {
        var items: [FeedItem] = []
        /// Where the next page starts; nil once the last is read.
        var nextCursor: String?
        var isLoading = false
        /// The first page has come back.
        var isLoaded = false
        var error: String?
    }

    enum ListState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var circles: [CircleSummary] = []
    private(set) var details: [String: CircleDetail] = [:]
    /// Each circle's Recent finds (issue #62), by circle id: the pages read so far, newest first.
    private(set) var feeds: [String: Feed] = [:]
    /// Each circle's goals (issue #65), by circle id: this month's goal first, then the custom goals.
    private(set) var goals: [String: [CircleGoal]] = [:]
    private(set) var listState: ListState = .idle
    /// The token of an invite link opened from outside the app, for the join screen.
    var pendingInvite: String?
    /// What the birder muted (issue #63): those circles' and friends' finds send no pushes.
    private(set) var mutes = Mutes()
    /// The accounts the birder blocked (issue #71): the server hides their finds and reactions.
    private(set) var blocked: [BlockedAccount] = []
    /// Runs after the birder creates or joins a circle: the push center asks for permission the first time.
    @ObservationIgnored var joinedCircle: (() async -> Void)?
    /// The latest reaction tap on each feed item, by item id.
    @ObservationIgnored private var reactionTurns: [String: Int] = [:]

    let account: AccountSession
    /// The circle server's client; the find outbox (issue #62) sends through the same one.
    let client: CircleClient?
    private let timeZone: () -> String
    private let log = Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "circles")

    init(account: AccountSession, client: CircleClient?, timeZone: @escaping () -> String = { TimeZone.current.identifier }) {
        self.account = account
        self.client = client
        self.timeZone = timeZone
    }

    /// Whether this build talks to a circle server at all (it needs the account's).
    var isAvailable: Bool { client != nil && account.status != .unavailable }

    func refresh() async {
        guard let client, account.isSignedIn else { return }
        if circles.isEmpty { listState = .loading }
        do {
            circles = try await account.withAccessToken(doing: "load your Guilds") { try await client.circles(accessToken: $0) }
            listState = .loaded
            if let mutes = try? await account.withAccessToken(doing: "load your Guilds", { try await client.mutes(accessToken: $0) }) {
                self.mutes = mutes
            }
            await loadBlocks()
        } catch {
            log.error("couldn't load circles: \(String(describing: error))")
            listState = .failed(Self.message(for: error, doing: "load your Guilds"))
        }
    }

    /// Creates and names a circle, with the birder as its creator and only member; it joins the list at once.
    @discardableResult
    func create(named name: String) async throws -> CircleDetail {
        let detail = try await call { try await $0.createCircle(named: name.trimmingCharacters(in: .whitespacesAndNewlines), timeZone: self.timeZone(), accessToken: $1) }
        remember(detail)
        await joinedCircle?()
        return detail
    }

    func loadDetail(id: String) async throws {
        do {
            remember(try await call { try await $0.circle(id: id, accessToken: $1) })
        } catch CircleError.notFound {
            // Removed, or left on another device: it is no longer the birder's.
            forget(id)
            throw CircleError.notFound
        }
    }

    func invite(circleID: String) async throws -> CircleInvite {
        try await call { try await $0.createInvite(circleID: circleID, accessToken: $1) }
    }

    func preview(token: String) async throws -> InvitePreview {
        try await call { try await $0.invitePreview(token: token, accessToken: $1) }
    }

    func accept(token: String) async throws -> CircleDetail {
        let detail = try await call { try await $0.acceptInvite(token: token, accessToken: $1) }
        remember(detail)
        await joinedCircle?()
        return detail
    }

    func leave(circleID: String) async throws {
        try await call { try await $0.leave(circleID: circleID, accessToken: $1) }
        forget(circleID)
    }

    func remove(memberID: String, circleID: String) async throws {
        try await call { try await $0.removeMember(memberID, circleID: circleID, accessToken: $1) }
        try? await loadDetail(id: circleID)
    }

    /// Shares a card by hand (issue #66). With a photo (faces blurred and metadata stripped already), it is uploaded
    /// first and the card names its key; `card` makes the card given that key. The feeds of the circles chosen are
    /// read again, so the card shows there at once.
    func shareCard(sightingID: UUID, photo: Data?, card: (String?) -> FindPolicy.Card) async throws {
        var key: String?
        if let photo {
            let upload = try await call { try await $0.photoUpload(sightingID: sightingID, accessToken: $1) }
            // The bucket takes the signed form, not the account's token.
            try await client?.uploadPhoto(photo, to: upload)
            key = upload.key
        }
        let shared = card(key)
        try await call { try await $0.shareCard(shared, sightingID: sightingID, accessToken: $1) }
        for circleID in shared.circleIDs where feeds[circleID] != nil {
            await loadFeed(circleID: circleID)
        }
    }

    /// Reads the circle's newest finds again, replacing what was read.
    func loadFeed(circleID: String) async {
        await readFeed(circleID: circleID, cursor: nil)
    }

    /// Reads the next page of the circle's finds, if there is one.
    func loadMoreFeed(circleID: String) async {
        guard let feed = feeds[circleID], let cursor = feed.nextCursor, !feed.isLoading else { return }
        await readFeed(circleID: circleID, cursor: cursor)
    }

    private func readFeed(circleID: String, cursor: String?) async {
        var feed = feeds[circleID] ?? Feed()
        feed.isLoading = true
        feeds[circleID] = feed
        do {
            let page = try await call { try await $0.feed(circleID: circleID, cursor: cursor, accessToken: $1) }
            feed.items = cursor == nil ? page.items : feed.items + page.items.filter { item in !feed.items.contains { $0.id == item.id } }
            feed.nextCursor = page.nextCursor
            feed.isLoaded = true
            feed.error = nil
        } catch {
            log.error("couldn't load the feed: \(String(describing: error))")
            feed.error = Self.message(for: error, doing: "load the finds")
        }
        feed.isLoading = false
        feeds[circleID] = feed
    }

    /// Reads the circle's goals and their progress again. A failure keeps what was read; the card has nothing to say
    /// about it beyond the feed's own error.
    func loadGoals(circleID: String) async {
        do {
            goals[circleID] = try await call { try await $0.goals(circleID: circleID, accessToken: $1) }
        } catch {
            log.error("couldn't load the goals: \(String(describing: error))")
        }
    }

    /// A custom goal for the circle; the list is read again so it lands in the server's order.
    @discardableResult
    func createGoal(_ draft: GoalDraft, circleID: String) async throws -> CircleGoal {
        var draft = draft
        draft.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let goal = try await call { try await $0.createGoal(draft, circleID: circleID, accessToken: $1) }
        await loadGoals(circleID: circleID)
        return goal
    }

    func deleteGoal(id: String, circleID: String) async throws {
        try await call { try await $0.deleteGoal(id: id, circleID: circleID, accessToken: $1) }
        goals[circleID]?.removeAll { $0.id == id }
    }

    /// A push came (issue #63): the list again, and the feeds of the circles it names (every feed the phone has read
    /// when it names none).
    func refreshAfterPush(circleIDs: [String]) async {
        guard account.isSignedIn else { return }
        await refresh()
        let open = circleIDs.isEmpty ? Array(feeds.keys) : circleIDs.filter { feeds[$0] != nil }
        for id in open {
            await loadFeed(circleID: id)
            // A find moves its circle's goals (issue #65).
            if goals[id] != nil { await loadGoals(circleID: id) }
        }
    }

    func setCircleMuted(_ muted: Bool, circleID: String) async throws {
        try await call { try await $0.setCircleMuted(muted, circleID: circleID, accessToken: $1) }
        if muted { mutes.circles.insert(circleID) } else { mutes.circles.remove(circleID) }
    }

    func setFriendMuted(_ muted: Bool, friendID: String) async throws {
        try await call { try await $0.setFriendMuted(muted, friendID: friendID, accessToken: $1) }
        if muted { mutes.friends.insert(friendID) } else { mutes.friends.remove(friendID) }
    }

    /// Gives or takes back the birder's reaction on a friend's find (issue #64). Every open feed holding the find
    /// shows it at once; the server's counts replace the guess when they come, and a failure puts the find back as
    /// it was and rethrows.
    /// Overlapping taps on one find answer out of order; only the latest tap's answer is shown.
    func react(_ kind: ReactionKind, given: Bool, to item: FeedItem) async throws {
        guard !item.isMine else { return }
        let before = item.reactions
        let turn = (reactionTurns[item.id] ?? 0) + 1
        reactionTurns[item.id] = turn
        update(item.id) { $0.reacting(kind, given: given) }
        do {
            let counts = try await call {
                try await $0.setReaction(kind, given: given, owner: item.owner.id, sightingID: item.sightingID, accessToken: $1)
            }
            if reactionTurns[item.id] == turn {
                update(item.id) { var item = $0; item.reactions = counts; return item }
            }
        } catch {
            log.error("couldn't react: \(String(describing: error))")
            if reactionTurns[item.id] == turn {
                update(item.id) { var item = $0; item.reactions = before; return item }
            }
            throw error
        }
    }

    /// Reports a find or a member (issue #71).
    func report(_ report: ReportDraft) async throws {
        try await call { try await $0.report(report, accessToken: $1) }
    }

    func loadBlocks() async {
        if let blocked = try? await call({ try await $0.blocks(accessToken: $1) }) {
            self.blocked = blocked
        }
    }

    /// Blocks or unblocks an account. Every open feed reloads, since the server leaves a blocked account's finds out.
    func setBlocked(_ isBlocked: Bool, accountID: String, name: String?) async throws {
        try await call { try await $0.setBlocked(isBlocked, accountID: accountID, accessToken: $1) }
        blocked.removeAll { $0.id == accountID }
        if isBlocked { blocked.append(BlockedAccount(id: accountID, displayName: name)) }
        for id in feeds.keys { await loadFeed(circleID: id) }
    }

    /// A friend's side of Compare birds (issue #64).
    func compare(friendID: String) async throws -> FriendBirds {
        try await call { try await $0.compare(friendID: friendID, accessToken: $1) }
    }

    private func update(_ itemID: String, _ change: (FeedItem) -> FeedItem) {
        for (circleID, feed) in feeds {
            guard let index = feed.items.firstIndex(where: { $0.id == itemID }) else { continue }
            feeds[circleID]?.items[index] = change(feed.items[index])
        }
    }

    /// Signed out: nothing of the circles stays on the phone (the root calls it whenever the account signs out).
    func clear() {
        circles = []
        details = [:]
        feeds = [:]
        goals = [:]
        mutes = Mutes()
        blocked = []
        listState = .idle
    }

    private func call<T>(_ body: (CircleClient, String) async throws -> T) async throws -> T {
        // Only reachable if a screen calls without checking `isAvailable`.
        guard let client else { throw CircleError.server(0) }
        return try await account.withAccessToken(doing: "reach your Guilds") { try await body(client, $0) }
    }

    private func remember(_ detail: CircleDetail) {
        details[detail.circle.id] = detail
        if let index = circles.firstIndex(where: { $0.id == detail.circle.id }) {
            circles[index] = detail.circle
        } else {
            circles.append(detail.circle)
        }
        if listState != .loaded { listState = .loaded }
    }

    private func forget(_ id: String) {
        circles.removeAll { $0.id == id }
        details[id] = nil
        feeds[id] = nil
        goals[id] = nil
    }

    /// The words for a failure, on the screen where it happened.
    static func message(for error: Error, doing action: String) -> String {
        switch error {
        case CircleError.full: "This Guild is full: a Guild holds 20 birders."
        case CircleError.inviteExpired: "This invitation has expired. Ask your friend for a new one."
        case CircleError.inviteRevoked: "This invitation no longer works for you. Ask the Guild for a new one."
        case CircleError.notFound: "This Guild or invitation isn't there any more."
        case CircleError.creatorOnly: "Only the Guild's creator can remove members."
        case CircleError.rejected: "Use a name of up to 40 characters, on one line."
        case CircleError.goalNotYours: "Only a goal's creator or the Guild's creator can delete it, and the monthly goal stays."
        case CircleError.tooManyReports: "You've sent a lot of reports today. Try again tomorrow, or email matt@lightsailvr.com."
        case CircleError.ownAccount: "You can't report or block yourself."
        case AuthError.sessionExpired: "You've been signed out. Sign in again to use your Guilds."
        default: "Couldn't \(action). Check your connection and try again."
        }
    }
}

extension CircleStore {
    /// Blocks live with the circles: any build with accounts has them (issue #71).
    static var blocksAvailable: Bool { AccountSession.isEnabledInThisBuild }

    /// The app's store: the bundled server's API, or none when the build has no server (the tab then says circles
    /// aren't available). In debug builds `-fakeCircles empty|some|offline`, or `-fakeAccount` alone, swaps in the in-memory
    /// fake, so the UI tests and screenshots need no network.
    static func forApp(account: AccountSession) -> CircleStore {
        #if DEBUG
        let defaults = UserDefaults.standard
        if let mode = defaults.string(forKey: "fakeCircles") ?? defaults.string(forKey: "fakeAccount").map({ _ in "empty" }) {
            return CircleStore(account: account, client: FakeCircleClient(seeded: mode == "some", offline: mode == "offline"))
        }
        #endif
        guard let server = AccountServer.bundled() else { return CircleStore(account: account, client: nil) }
        return CircleStore(account: account, client: HTTPCircleClient(baseURL: server.apiURL))
    }
}
