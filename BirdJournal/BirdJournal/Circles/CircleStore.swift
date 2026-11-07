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
        /// The first page has come back, this launch or from the cache.
        var isLoaded = false
        var error: String?
        /// How much of `items` is the first page, the part the cache keeps, and where its next page starts.
        var firstPageCount = 0
        var firstPageCursor: String?

        /// Whether the finds just read, newest first, come down as far as what's been read: if not, there may be finds between.
        func meets(_ newest: [FeedItem]) -> Bool {
            guard let reach = newest.last.map({ ($0.foundAt, $0.id) }) else { return false }
            return items.contains { ($0.foundAt, $0.id) >= reach }
        }

        /// The newest finds, as just read, laid over what's been read: what's older than they reach stays, and with it the place
        /// to read on from, so a birder further down keeps their rows. What's gone from within their reach is gone.
        ///
        /// Reaching the feed's end, there's nothing older to keep. Not coming down as far as what's been read, there may be finds
        /// between that a marked one could be among, so they replace it and read on from there, and "More finds" reaches everything.
        /// Having read nothing it can show (the server leaves a blocked account's finds out after it pages), it can't say what's
        /// changed, so the rows stay.
        mutating func layOver(_ newest: [FeedItem], nextCursor cursor: String?) {
            guard cursor != nil else {
                items = newest
                nextCursor = nil
                return
            }
            guard let reach = newest.last.map({ ($0.foundAt, $0.id) }) else {
                if items.isEmpty { nextCursor = cursor }
                return
            }
            guard meets(newest) else {
                items = newest
                nextCursor = cursor
                return
            }
            let older = items.filter { old in (old.foundAt, old.id) < reach && !newest.contains { $0.id == old.id } }
            items = newest + older
            if older.isEmpty { nextCursor = cursor }
        }

        /// There's nothing here and nothing further to read. Rows can be empty with a cursor still leading on, when all that's been
        /// read so far is someone blocked, and "No finds yet" wouldn't be true.
        var hasNoFinds: Bool { isLoaded && items.isEmpty && nextCursor == nil }

        /// Takes these accounts' finds out, keeping the first page's count true.
        mutating func removeFinds(of accounts: [String]) {
            guard !accounts.isEmpty else { return }
            firstPageCount = items.prefix(firstPageCount).count { !accounts.contains($0.owner.id) }
            items.removeAll { accounts.contains($0.owner.id) }
        }
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
    /// Each friend's side of Compare birds as last read (issue #150), by friend id: this launch only.
    private(set) var friendBirds: [String: FriendBirds] = [:]
    /// The finds whose pages have been open, as last read (issue #150): a page keeps its find when a read of the feeds no longer
    /// holds it, until its owner is blocked or its Guilds are gone. This launch only, by `heldFindKey`.
    private var heldFinds: [String: FindEntry] = [:]
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
    /// The Guilds whose detail and goals have been read this launch, rather than coming from the cache.
    @ObservationIgnored private var freshDetails: Set<String> = []
    @ObservationIgnored private var freshGoals: Set<String> = []
    /// When each Guild's first page was last read, this launch.
    @ObservationIgnored private var firstPageReads: [String: Date] = [:]
    /// Bumped by `clear`, so an answer on its way when the birder signed out is dropped, not stored.
    @ObservationIgnored private var session = 0
    @ObservationIgnored private var isCacheWriteWaiting = false

    let account: AccountSession
    /// The circle server's client; the find outbox (issue #62) sends through the same one.
    let client: CircleClient?
    private let timeZone: () -> String
    private let cache: CircleCache?
    private let log = Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "circles")

    /// - Parameter cache: where the last-known content lives between launches (issue #150). What it holds is drawn at once if
    ///   the birder is signed in. A cache found while signed out (the app quit before it could clear) goes.
    init(account: AccountSession, client: CircleClient?, timeZone: @escaping () -> String = { TimeZone.current.identifier }, cache: CircleCache? = nil) {
        self.account = account
        self.client = client
        self.timeZone = timeZone
        self.cache = cache
        guard account.isSignedIn else {
            cache?.remove()
            return
        }
        if let snapshot = cache?.load() { restore(snapshot) }
    }

    /// Whether this build talks to a circle server at all (it needs the account's).
    var isAvailable: Bool { client != nil && account.status != .unavailable }

    func refresh() async {
        guard let client, account.isSignedIn else { return }
        if circles.isEmpty, listState != .loaded { listState = .loading }
        let session = session
        do {
            let circles = try await account.withAccessToken(doing: "load your Guilds") { try await client.circles(accessToken: $0) }
            guard session == self.session else { return }
            self.circles = circles
            listState = .loaded
            cacheLater()
            if let mutes = try? await account.withAccessToken(doing: "load your Guilds", { try await client.mutes(accessToken: $0) }), session == self.session {
                self.mutes = mutes
            }
            await loadBlocks()
        } catch {
            guard session == self.session else { return }
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
        let session = session
        do {
            let detail = try await call { try await $0.circle(id: id, accessToken: $1) }
            guard session == self.session else { return }
            remember(detail)
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
            await refreshFeed(circleID: circleID)
        }
    }

    /// Reads the circle's newest finds again, replacing what was read.
    func loadFeed(circleID: String) async {
        await readFeed(circleID: circleID, cursor: nil)
    }

    /// How many pages a refresh reads looking for what's already been read: past that, it starts again from what it has read.
    private static let refreshReach = 5
    /// How many pages in a row it reads with nothing on them it can show: a page can be all someone blocked.
    private static let emptyPagesReadOn = 20

    /// The next page with something on it, or the feed's end, or as far as it's worth going in one go.
    private func readPage(circleID: String, cursor: String?) async throws -> FeedPage {
        var pages = 0
        var reading = cursor
        while true {
            let from = reading
            let page = try await call { try await $0.feed(circleID: circleID, cursor: from, accessToken: $1) }
            pages += 1
            guard page.items.isEmpty, let next = page.nextCursor, pages < Self.emptyPagesReadOn else { return page }
            reading = next
        }
    }

    /// Reads the circle's newest finds and lays them over what's been read, for what arrives by itself: a push, or the birder's own
    /// share or block. Unlike `loadFeed`, the pages already read stay, so the merged feed's horizon stays where it was, and nothing
    /// disappears from under a birder further down. A failure leaves the rows, and says so.
    func refreshFeed(circleID: String) async {
        guard let known = feeds[circleID], known.isLoaded else { return await loadFeed(circleID: circleID) }
        feeds[circleID]?.isLoading = true
        let session = session
        do {
            var newest: [FeedItem] = []
            var first: FeedPage?
            var cursor: String?
            var pages = 0
            repeat {
                let page = try await readPage(circleID: circleID, cursor: cursor)
                if first == nil { first = page }
                newest += page.items
                cursor = page.nextCursor
                pages += 1
            } while cursor != nil && pages < Self.refreshReach && !newest.isEmpty && !known.meets(newest)
            guard session == self.session else { return }
            // As it is now: a reaction, a block or another page may have landed while these were on their way.
            var feed = feeds[circleID] ?? Feed()
            feed.layOver(newest, nextCursor: cursor)
            feed.isLoaded = true
            feed.error = nil
            feed.firstPageCount = first?.items.count ?? 0
            feed.firstPageCursor = first?.nextCursor
            firstPageReads[circleID] = .now
            cacheLater()
            feed.removeFinds(of: blocked.map(\.id))
            feed.isLoading = false
            feeds[circleID] = feed
        } catch {
            guard session == self.session else { return }
            log.error("couldn't refresh the feed: \(String(describing: error))")
            feeds[circleID]?.error = Self.message(for: error, doing: "load the finds")
            feeds[circleID]?.isLoading = false
        }
    }

    /// Reads the next page of the circle's finds, if there is one.
    func loadMoreFeed(circleID: String) async {
        guard let feed = feeds[circleID], let cursor = feed.nextCursor, !feed.isLoading else { return }
        await readFeed(circleID: circleID, cursor: cursor)
    }

    private func readFeed(circleID: String, cursor: String?) async {
        feeds[circleID, default: Feed()].isLoading = true
        let session = session
        do {
            let page = try await readPage(circleID: circleID, cursor: cursor)
            guard session == self.session else { return }
            // As it is now: a reaction or a block may have changed it while this page was on its way.
            var feed = feeds[circleID] ?? Feed()
            feed.items = cursor == nil ? page.items : feed.items + page.items.filter { item in !feed.items.contains { $0.id == item.id } }
            feed.nextCursor = page.nextCursor
            feed.isLoaded = true
            feed.error = nil
            if cursor == nil {
                feed.firstPageCount = page.items.count
                feed.firstPageCursor = page.nextCursor
                firstPageReads[circleID] = .now
                cacheLater()
            }
            feed.removeFinds(of: blocked.map(\.id))
            feed.isLoading = false
            feeds[circleID] = feed
        } catch {
            guard session == self.session else { return }
            log.error("couldn't load the feed: \(String(describing: error))")
            feeds[circleID]?.error = Self.message(for: error, doing: "load the finds")
            feeds[circleID]?.isLoading = false
        }
    }

    // MARK: - The merged feed

    /// What's new across every Guild (issue #150, G3), for the Guilds tab: each Guild's loaded pages merged by time.
    struct MergedFeed: Equatable {
        var entries: [FindEntry] = []
        /// A Guild has another page.
        var hasMore = false
        var isLoading = false
        /// Every Guild's first page has come back, this launch or from the cache.
        var isLoaded = false
        var error: String?

        /// There's nothing to show and nothing further to read.
        var hasNoFinds: Bool { isLoaded && entries.isEmpty && !hasMore }
    }

    /// The Guilds' feeds as one list. It stops where a Guild's unread pages could still hold something newer, so a find never
    /// lands in the middle of what the birder has already read: "More finds" carries on from there.
    var mergedFeed: MergedFeed {
        let read = circles.map { (circleID: $0.id, feed: feeds[$0.id] ?? Feed()) }
        var entries = FindEntry.merging(read.map { ($0.circleID, $0.feed.items) }, blocked: Set(blocked.map(\.id)))
        if let horizon = read.compactMap({ $0.feed.nextCursor == nil ? nil : $0.feed.items.last?.foundAt }).max() {
            entries.removeAll { $0.item.foundAt < horizon }
        }
        return MergedFeed(
            entries: entries,
            hasMore: read.contains { $0.feed.nextCursor != nil },
            isLoading: read.contains { $0.feed.isLoading },
            isLoaded: read.allSatisfy(\.feed.isLoaded),
            error: read.lazy.compactMap(\.feed.error).first
        )
    }

    /// One find, for its page: as the Guild it was opened in has it, or opened from the feed across Guilds, as every Guild the birder
    /// has read it in knows it. A row and its page say the same, so a mark from another Guild's copy stays there. A find a read
    /// no longer holds stays as it last was, once `holdOpen` has it: only a block, or its Guilds going, takes it away.
    func entry(id: String, openedIn circleID: String? = nil) -> FindEntry? {
        if let live = liveEntry(id: id, openedIn: circleID) { return live }
        guard let held = heldFinds[Self.heldFindKey(id: id, openedIn: circleID)], !blocked.contains(where: { $0.id == held.item.owner.id }),
              circles.contains(where: { held.circleIDs.contains($0.id) })
        else { return nil }
        return held
    }

    /// Remembers the find on an open page, as it is now.
    func holdOpen(id: String, openedIn circleID: String? = nil) {
        guard let live = liveEntry(id: id, openedIn: circleID) else { return }
        let key = Self.heldFindKey(id: id, openedIn: circleID)
        if heldFinds[key] != live { heldFinds[key] = live }
    }

    private func liveEntry(id: String, openedIn circleID: String?) -> FindEntry? {
        let read = circles
            .filter { circleID == nil || $0.id == circleID }
            .compactMap { circle in feeds[circle.id].map { (circleID: circle.id, items: $0.items.filter { $0.id == id }) } }
        return FindEntry.merging(read, blocked: Set(blocked.map(\.id))).first
    }

    private static func heldFindKey(id: String, openedIn circleID: String?) -> String {
        "\(circleID ?? "")|\(id)"
    }

    /// Reads these Guilds' newest finds again, side by side; every Guild's unless it says.
    func loadMergedFeed(circleIDs: [String]? = nil) async {
        await withDiscardingTaskGroup { group in
            for id in circleIDs ?? circles.map(\.id) {
                group.addTask { await self.loadFeed(circleID: id) }
            }
        }
    }

    /// Whether a screen coming on screen should read this Guild's newest finds: it hasn't been read this launch, though the cache
    /// may have drawn it, or it's a while since it was. Reading a first page replaces what was read, and can move the merged feed's
    /// horizon, so once the birder has gone further down any Guild's finds nothing moves: back from a find's page, what they were
    /// reading is still there, until they pull to refresh.
    func isFeedStale(_ circleID: String, now: Date = .now) -> Bool {
        guard let read = firstPageReads[circleID], feeds[circleID] != nil else { return true }
        let hasGoneFurther = feeds.values.contains { $0.items.count > $0.firstPageCount }
        return !hasGoneFurther && now.timeIntervalSince(read) > Self.feedKeepsFor
    }

    /// The signed-in birder among a Guild's members: the account's ID, or until the account is read (it may not be, on a cached page
    /// with no connection), the sign-in's, or the creator's if the birder created the circle.
    func myID(in detail: CircleDetail) -> String? {
        account.account?.id ?? account.identity.subject ?? (detail.circle.isCreator ? detail.circle.createdBy : nil)
    }

    /// A Guild's members as its page shows them: the blocked are gone from its faces and Compare, as their finds are. The Info sheet
    /// still lists them, since that's where they're unblocked.
    func visibleMembers(of detail: CircleDetail) -> [CircleMember] {
        detail.members.filter { member in !blocked.contains { $0.id == member.id } }
    }

    private static let feedKeepsFor: TimeInterval = 60

    /// The next page, from whichever Guild's next item is newest: the one whose last read find is newest, since its next find
    /// can't be newer than that and any other's is older still. A Guild that has shown nothing, because all it has read so far is
    /// someone blocked, goes first. It keeps reading until a new find shows or the pages run out.
    func loadMoreMergedFeed() async {
        let shown = mergedFeed.entries.count
        while mergedFeed.entries.count == shown, let next = nextFeedToRead {
            let before = feeds[next]?.nextCursor
            await loadMoreFeed(circleID: next)
            // A failure, or a read already on its way: it says so, and the birder can ask again.
            if feeds[next]?.nextCursor == before { return }
        }
    }

    private var nextFeedToRead: String? {
        circles
            .compactMap { circle -> (id: String, last: Date)? in
                guard let feed = feeds[circle.id], feed.nextCursor != nil else { return nil }
                return (circle.id, feed.items.last?.foundAt ?? .distantFuture)
            }
            .max { $0.last < $1.last }?
            .id
    }

    /// Reads the circle's goals and their progress again. A failure keeps what was read; the card has nothing to say
    /// about it beyond the feed's own error.
    func loadGoals(circleID: String) async {
        let session = session
        do {
            let read = try await call { try await $0.goals(circleID: circleID, accessToken: $1) }
            guard session == self.session else { return }
            goals[circleID] = read
            freshGoals.insert(circleID)
            cacheLater()
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
        cacheLater()
    }

    /// A push came (issue #63): the list again, and the feeds of the circles it names (every feed the phone has read
    /// when it names none).
    func refreshAfterPush(circleIDs: [String]) async {
        guard account.isSignedIn else { return }
        await refresh()
        let open = circleIDs.isEmpty ? Array(feeds.keys) : circleIDs.filter { feeds[$0] != nil }
        for id in open {
            await refreshFeed(circleID: id)
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
                cacheLater()
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
        let session = session
        if let blocked = try? await call({ try await $0.blocks(accessToken: $1) }), session == self.session {
            self.blocked = blocked
            forgetFinds(of: blocked.map(\.id))
        }
    }

    /// Blocks or unblocks an account. Every open feed reloads, since the server leaves a blocked account's finds out.
    func setBlocked(_ isBlocked: Bool, accountID: String, name: String?) async throws {
        try await call { try await $0.setBlocked(isBlocked, accountID: accountID, accessToken: $1) }
        blocked.removeAll { $0.id == accountID }
        if isBlocked {
            blocked.append(BlockedAccount(id: accountID, displayName: name))
            forgetFinds(of: [accountID])
        }
        // A block only takes rows away, which has happened. An unblock brings back rows on pages already read, so it starts again.
        for id in feeds.keys {
            if isBlocked { await refreshFeed(circleID: id) } else { await loadFeed(circleID: id) }
        }
    }

    /// Blocked, here or on another device: their finds and birds go at once, in memory and on disk, without waiting on a
    /// reload, which could fail.
    private func forgetFinds(of accounts: [String]) {
        guard !accounts.isEmpty else { return }
        for id in feeds.keys { feeds[id]?.removeFinds(of: accounts) }
        for id in accounts { friendBirds[id] = nil }
        cacheLater()
    }

    /// A friend's side of Compare birds (issue #64). The server answers not found for someone blocked, or no longer in a Guild
    /// with the birder, and what was last read of them goes with that answer. An answer otherwise is the truth, even about
    /// someone `blocked` still lists (unblocked on another device), unless the block landed while the answer was on its way,
    /// which reads as the server would now answer.
    @discardableResult
    func compare(friendID: String) async throws -> FriendBirds {
        let session = session
        let wasBlocked = blocked.contains { $0.id == friendID }
        do {
            let birds = try await call { try await $0.compare(friendID: friendID, accessToken: $1) }
            if !wasBlocked, blocked.contains(where: { $0.id == friendID }) { throw CircleError.notFound }
            if session == self.session { friendBirds[friendID] = birds }
            return birds
        } catch CircleError.notFound {
            if session == self.session { friendBirds[friendID] = nil }
            throw CircleError.notFound
        }
    }

    private func update(_ itemID: String, _ change: (FeedItem) -> FeedItem) {
        for (circleID, feed) in feeds {
            guard let index = feed.items.firstIndex(where: { $0.id == itemID }) else { continue }
            feeds[circleID]?.items[index] = change(feed.items[index])
        }
        for (key, held) in heldFinds where held.id == itemID {
            heldFinds[key]?.item = change(held.item)
        }
    }

    /// Whether a screen should read the Guild's detail: it hasn't been read this launch, though the cache may have drawn one.
    func needsDetail(_ circleID: String) -> Bool { !freshDetails.contains(circleID) }

    /// Whether a screen should read the Guild's goals: as for its detail.
    func needsGoals(_ circleID: String) -> Bool { !freshGoals.contains(circleID) }

    /// Signed out or the account deleted: nothing of the circles stays on the phone, in memory or on disk (the root calls it
    /// whenever the account signs out).
    func clear() {
        session += 1
        circles = []
        details = [:]
        feeds = [:]
        goals = [:]
        friendBirds = [:]
        heldFinds = [:]
        mutes = Mutes()
        blocked = []
        listState = .idle
        freshDetails = []
        freshGoals = []
        firstPageReads = [:]
        cache?.remove()
    }

    // MARK: - The cache

    private func restore(_ snapshot: CircleSnapshot) {
        circles = snapshot.circles
        details = snapshot.details
        goals = snapshot.goals
        feeds = snapshot.feeds.mapValues { page in
            Feed(items: page.items, nextCursor: page.nextCursor, isLoaded: true, firstPageCount: page.items.count, firstPageCursor: page.nextCursor)
        }
        listState = .loaded
    }

    /// What goes on disk: the Guilds the birder is in now, and the first page of each feed.
    var snapshot: CircleSnapshot {
        let ids = Set(circles.map(\.id))
        return CircleSnapshot(
            circles: circles,
            details: details.filter { ids.contains($0.key) },
            feeds: feeds.filter { ids.contains($0.key) && $0.value.isLoaded }.mapValues { feed in
                FeedPage(items: Array(feed.items.prefix(feed.firstPageCount)), nextCursor: feed.firstPageCursor)
            },
            goals: goals.filter { ids.contains($0.key) }
        )
    }

    /// Writes the snapshot shortly: a refresh of several Guilds asks many times over and writes once.
    private func cacheLater() {
        guard cache != nil, !isCacheWriteWaiting else { return }
        isCacheWriteWaiting = true
        let session = session
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self else { return }
            isCacheWriteWaiting = false
            if session == self.session { writeCache() }
        }
    }

    /// Writes the snapshot now, signed in. The store's own writes come through here.
    func writeCache() {
        guard account.isSignedIn else { return }
        cache?.save(snapshot)
    }

    private func call<T>(_ body: (CircleClient, String) async throws -> T) async throws -> T {
        // Only reachable if a screen calls without checking `isAvailable`.
        guard let client else { throw CircleError.server(0) }
        return try await account.withAccessToken(doing: "reach your Guilds") { try await body(client, $0) }
    }

    private func remember(_ detail: CircleDetail) {
        // An answer that lands after the sign-out isn't kept.
        guard account.isSignedIn else { return }
        details[detail.circle.id] = detail
        freshDetails.insert(detail.circle.id)
        cacheLater()
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
        freshDetails.remove(id)
        freshGoals.remove(id)
        firstPageReads[id] = nil
        cacheLater()
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
    /// aren't available). In debug builds `-fakeCircles empty|one|some|shared|reference|offline`, or `-fakeAccount` alone, swaps in the in-memory
    /// fake, so the UI tests and screenshots need no network.
    static func forApp(account: AccountSession) -> CircleStore {
        #if DEBUG
        let defaults = UserDefaults.standard
        if let mode = defaults.string(forKey: "fakeCircles") ?? defaults.string(forKey: "fakeAccount").map({ _ in "empty" }) {
            let client = FakeCircleClient(seeded: ["some", "shared", "reference"].contains(mode), offline: mode == "offline")
            if mode == "one" { client.seedOneGuild() }
            if mode == "shared" { client.seedSharedFinds() }
            if mode == "reference" { client.seedReference() }
            let lateFinds = defaults.integer(forKey: "fakeLateFinds")
            client.latency = .seconds(defaults.double(forKey: "fakeCircleLatency"))
            client.goalRisesBy = defaults.integer(forKey: "fakeGoalRises")
            client.reactionsFail = defaults.bool(forKey: "fakeReactionsFail")
            // `-circleCacheFile <name>` keeps the fakes' last-known content in tmp, so a UI test can relaunch over it.
            let cache = defaults.string(forKey: "circleCacheFile").map { CircleCache(fileURL: URL.temporaryDirectory.appending(path: "\($0).json")) }
            let store = CircleStore(account: account, client: client, cache: cache)
            // `-fakeLateFinds <n>` (issue #150): n finds land `-fakeLateFindsAfter <seconds>` from launch, and a push says so.
            if lateFinds > 0 {
                let delay = defaults.double(forKey: "fakeLateFindsAfter")
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(delay))
                    client.addLateFinds(lateFinds)
                    await store.refreshAfterPush(circleIDs: [])
                    LateFindsProbe.shared.hasLanded = true
                }
            }
            return store
        }
        #endif
        guard let server = AccountServer.bundled() else { return CircleStore(account: account, client: nil) }
        return CircleStore(account: account, client: HTTPCircleClient(baseURL: server.apiURL), cache: .forApp())
    }
}
