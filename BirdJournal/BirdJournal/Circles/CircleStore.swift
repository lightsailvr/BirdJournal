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
    private(set) var listState: ListState = .idle
    /// The token of an invite link opened from outside the app, for the join screen.
    var pendingInvite: String?

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
            circles = try await account.withAccessToken(doing: "load your circles") { try await client.circles(accessToken: $0) }
            listState = .loaded
        } catch {
            log.error("couldn't load circles: \(String(describing: error))")
            listState = .failed(Self.message(for: error, doing: "load your circles"))
        }
    }

    /// Creates and names a circle, with the birder as its creator and only member; it joins the list at once.
    @discardableResult
    func create(named name: String) async throws -> CircleDetail {
        let detail = try await call { try await $0.createCircle(named: name.trimmingCharacters(in: .whitespacesAndNewlines), timeZone: self.timeZone(), accessToken: $1) }
        remember(detail)
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

    /// Signed out: nothing of the circles stays on the phone (the root calls it whenever the account signs out).
    func clear() {
        circles = []
        details = [:]
        feeds = [:]
        listState = .idle
    }

    private func call<T>(_ body: (CircleClient, String) async throws -> T) async throws -> T {
        // Only reachable if a screen calls without checking `isAvailable`.
        guard let client else { throw CircleError.server(0) }
        return try await account.withAccessToken(doing: "reach your circles") { try await body(client, $0) }
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
    }

    /// The words for a failure, on the screen where it happened.
    static func message(for error: Error, doing action: String) -> String {
        switch error {
        case CircleError.full: "This circle is full: a circle holds 20 birders."
        case CircleError.inviteExpired: "This invitation has expired. Ask your friend for a new one."
        case CircleError.inviteRevoked: "This invitation no longer works for you. Ask the circle for a new one."
        case CircleError.notFound: "This circle or invitation isn't there any more."
        case CircleError.creatorOnly: "Only the circle's creator can remove members."
        case CircleError.rejected: "Use a name of up to 40 characters, on one line."
        case AuthError.sessionExpired: "You've been signed out. Sign in again to use your circles."
        default: "Couldn't \(action). Check your connection and try again."
        }
    }
}

extension CircleStore {
    /// The app's store: the bundled server's API, or none when the build has no server (the tab then says circles
    /// aren't available). In debug builds `-fakeCircles empty|some`, or `-fakeAccount` alone, swaps in the in-memory
    /// fake, so the UI tests and screenshots need no network.
    static func forApp(account: AccountSession) -> CircleStore {
        #if DEBUG
        let defaults = UserDefaults.standard
        if let mode = defaults.string(forKey: "fakeCircles") ?? defaults.string(forKey: "fakeAccount").map({ _ in "empty" }) {
            return CircleStore(account: account, client: FakeCircleClient(seeded: mode == "some"))
        }
        #endif
        guard let server = AccountServer.bundled() else { return CircleStore(account: account, client: nil) }
        return CircleStore(account: account, client: HTTPCircleClient(baseURL: server.apiURL))
    }
}
