import Foundation
import Observation
import OSLog
import UserNotifications

/// Which APNs the phone's token belongs to (issue #63): `sandbox` for development-signed builds (Xcode, Debug),
/// `production` for TestFlight and the App Store. Read from the provisioning profile's `aps-environment`; a build
/// without one (the simulator) is sandbox.
enum PushEnvironment: String, Codable, Sendable {
    case sandbox
    case production

    static func current(bundle: Bundle = .main) -> PushEnvironment {
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return .sandbox }
        return fromProvisioningProfile(data) ?? .sandbox
    }

    /// The profile is a signed CMS envelope around a plist; the plist sits in it as plain text.
    static func fromProvisioningProfile(_ data: Data) -> PushEnvironment? {
        guard let text = String(data: data, encoding: .isoLatin1),
              let start = text.range(of: "<?xml"), let end = text.range(of: "</plist>", range: start.upperBound..<text.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: Data(text[start.lowerBound..<end.upperBound].utf8), format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let environment = entitlements["aps-environment"] as? String else { return nil }
        return environment == "production" ? .production : .sandbox
    }
}

/// A friend's notable find as a push carries it (backend `find_summary`): what the lens's friend banner (#67) shows.
struct FriendFind: Equatable, Decodable, Sendable {
    var owner: String
    var ownerName: String?
    var sightingID: String
    var speciesID: String
    var scientificName: String
    var commonName: String
    var method: String
    var place: String?
    var foundAt: Date
    var legendary: Bool
    var rarity: String?
    var circleFirst: Bool
    var circleIDs: [String]

    enum CodingKeys: String, CodingKey {
        case owner
        case ownerName = "owner_name"
        case sightingID = "sighting_id"
        case speciesID = "species_id"
        case scientificName = "scientific_name"
        case commonName = "common_name"
        case method, place
        case foundAt = "found_at"
        case legendary, rarity
        case circleFirst = "circle_first"
        case circleIDs = "circle_ids"
    }

    var friendName: String { ownerName ?? "A friend" }
}

/// What a push from the BirdJournal server says, read from its payload's custom keys.
enum PushMessage: Equatable {
    /// A friend's new patch (the push's `legendary` flag until #136), circle first, or Rare or Exceptional find.
    case notable(FriendFind)
    /// "Maya found 6 birds in Pasadena".
    case digest(friend: String)
    /// Silent: a friend's ordinary find landed in these circles.
    case refresh(circleIDs: [String])
    /// "Maya reacted to your Black Phoebe" (issue #64): the find's circles, whose feeds show the new counts.
    case reaction(sightingID: String, circleIDs: [String])

    init?(userInfo: [AnyHashable: Any]) {
        switch userInfo["kind"] as? String {
        case "notable":
            guard let find = userInfo["find"],
                  let data = try? JSONSerialization.data(withJSONObject: find) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let summary = try? decoder.decode(FriendFind.self, from: data) else { return nil }
            self = .notable(summary)
        case "digest":
            guard let friend = userInfo["friend"] as? String else { return nil }
            self = .digest(friend: friend)
        case "refresh":
            self = .refresh(circleIDs: userInfo["circle_ids"] as? [String] ?? [])
        case "reaction":
            guard let sighting = userInfo["sighting_id"] as? String else { return nil }
            self = .reaction(sightingID: sighting, circleIDs: userInfo["circle_ids"] as? [String] ?? [])
        default:
            return nil
        }
    }

    /// The circles whose feeds to read again; empty means every one the phone has open.
    var circleIDs: [String] {
        switch self {
        case .notable(let find): find.circleIDs
        case .digest: []
        case .refresh(let ids): ids
        case .reaction(_, let ids): ids
        }
    }
}

/// Where notification permission stands.
enum PushPermission: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
}

/// The system's notification permission, behind a protocol so the tests and the UI tests can answer for it.
protocol NotificationAuthorizing: AnyObject {
    func permission() async -> PushPermission
    /// Shows the system prompt (only ever once per install); true when allowed.
    func request() async -> Bool
}

final class SystemNotificationAuthorizer: NotificationAuthorizing {
    func permission() async -> PushPermission {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        default: .authorized
        }
    }

    func request() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }
}

/// Pushes on the phone (issue #63): asks for permission, with an explanation, when the birder creates or joins their
/// first circle; registers the phone's APNs token with the signed-in account (and takes it off at sign-out); and
/// handles what arrives: every push refreshes the circle feeds, a notable find is kept as `latestFriendFind` and sent
/// to `friendFinds()` subscribers for the lens banner (#67), and a tapped one opens its circle.
@MainActor
@Observable
final class PushCenter {
    /// Set when the birder answered the explanation ("Turn on notifications" or "Not now"), not when it was raised.
    static let askedKey = "pushPermissionExplained"
    /// Raised but not answered yet (issue #107): the next Circles tab or circle page offers it once more.
    static let pendingKey = "pushPermissionExplanationPending"
    /// Why, before the system's prompt.
    static let explanation = "Featherguild can tell you when someone in your Guilds sews a new patch, finds a first for the Guild or a rare bird, and bundles their other finds into one notification every couple of hours. You can mute a Guild or a friend at any time."

    private(set) var permission: PushPermission?
    /// The explanation before the system prompt is raised. A dropped alert can leave it up with nothing on screen.
    var isExplaining = false
    /// The phone's APNs token, hex, once iOS has given one.
    private(set) var deviceToken: String?
    let environment: PushEnvironment
    /// The last notable find a push brought.
    private(set) var latestFriendFind: FriendFind?
    /// A tapped push asks the root to open the Circles tab, at this circle when there is one ("" for the list).
    var pendingCircle: String?

    private let account: AccountSession
    private let client: CircleClient?
    private let authorizer: NotificationAuthorizing
    private let registerForRemoteNotifications: () -> Void
    private let defaults: UserDefaults
    private let explanationDelay: Duration
    /// The explanation waits out its delay.
    @ObservationIgnored private var explanationScheduled = false
    /// Reads the circles and their feeds again after a push.
    @ObservationIgnored var refresh: (([String]) async -> Void)?
    @ObservationIgnored private var subscribers: [UUID: AsyncStream<FriendFind>.Continuation] = [:]
    /// The account the token was last sent for, so a launch doesn't send it twice and a new account does.
    @ObservationIgnored private var registeredFor: (token: String, subject: String)?
    private let log = Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "push")

    init(
        account: AccountSession,
        client: CircleClient?,
        authorizer: NotificationAuthorizing,
        environment: PushEnvironment = .current(),
        defaults: UserDefaults = .standard,
        explanationDelay: Duration = .milliseconds(600),
        registerForRemoteNotifications: @escaping () -> Void
    ) {
        self.account = account
        self.client = client
        self.authorizer = authorizer
        self.environment = environment
        self.defaults = defaults
        self.explanationDelay = explanationDelay
        self.registerForRemoteNotifications = registerForRemoteNotifications
        account.beforeSignOut = { [weak self] accessToken in await self?.unregister(accessToken: accessToken) }
    }

    /// Whether this build has pushes at all: the account's switch (#88) and a server.
    var isAvailable: Bool { client != nil && account.status != .unavailable }

    /// At launch and on becoming active: reads the permission (Settings may have changed it) and, if allowed, asks iOS
    /// for the token again (it hands back the same one, or a new one after a restore).
    func refreshPermission() async {
        guard isAvailable else { return }
        permission = await authorizer.permission()
        if permission == .authorized, account.isSignedIn { registerForRemoteNotifications() }
    }

    /// The birder created or joined a circle: the first time, explain pushes before the system asks. It counts as
    /// asked only once the birder answers (issue #107): until then it is pending, and `circlesAppeared()` offers it
    /// once more if it never got on screen.
    func joinedCircle() async {
        guard isAvailable, !defaults.bool(forKey: Self.askedKey) else { return }
        permission = await authorizer.permission()
        guard permission == .notDetermined else { return }
        defaults.set(true, forKey: Self.pendingKey)
        explain()
    }

    /// The Circles tab or a circle's page appeared: an explanation offered but never answered (dropped while a sheet
    /// went away, or the app was closed over it) is offered once more. One retry only; after that it waits for the
    /// next create or join.
    func circlesAppeared() async {
        guard isAvailable, account.isSignedIn, !explanationScheduled, defaults.bool(forKey: Self.pendingKey),
              !defaults.bool(forKey: Self.askedKey) else { return }
        defaults.set(false, forKey: Self.pendingKey)
        permission = await authorizer.permission()
        guard permission == .notDetermined else { return }
        explain()
    }

    /// Raises the explanation, after the delay. It is lowered first, so a dropped alert whose binding was left up
    /// shows again.
    private func explain() {
        guard !explanationScheduled else { return }
        isExplaining = false
        guard explanationDelay > .zero else {
            isExplaining = true
            return
        }
        // The circle's sheet or the join screen is still going away; an alert raised during that is dropped.
        explanationScheduled = true
        let delay = explanationDelay
        Task {
            try? await Task.sleep(for: delay)
            explanationScheduled = false
            // Answered meanwhile (the circle page's button): nothing to explain.
            if !defaults.bool(forKey: Self.askedKey) { isExplaining = true }
        }
    }

    /// The birder answered the explanation, or the circle page's button, so nothing asks again by itself.
    private func answered() {
        defaults.set(true, forKey: Self.askedKey)
        defaults.set(false, forKey: Self.pendingKey)
        isExplaining = false
    }

    /// "Turn on notifications", from the explanation or the circle page: the system prompt, or Settings once denied.
    func turnOn() async {
        answered()
        permission = await authorizer.permission()
        guard permission == .notDetermined else { return }
        permission = await authorizer.request() ? .authorized : .denied
        if permission == .authorized { registerForRemoteNotifications() }
    }

    func notNow() {
        answered()
    }

    /// iOS gave the phone its token.
    func didRegister(deviceToken data: Data) async {
        deviceToken = data.map { String(format: "%02x", $0) }.joined()
        await sendToken()
    }

    func didFailToRegister(_ error: Error) {
        log.error("couldn't register for pushes: \(String(describing: error))")
    }

    /// Signed in (again, or as someone else): the token goes to the account.
    func accountChanged() async {
        if account.isSignedIn {
            await refreshPermission()
            await sendToken()
        } else {
            registeredFor = nil
        }
    }

    /// A push arrived, in the foreground or in the background.
    func received(_ userInfo: [AnyHashable: Any]) async {
        guard let message = PushMessage(userInfo: userInfo) else { return }
        if case .notable(let find) = message, latestFriendFind?.sightingID != find.sightingID || latestFriendFind?.owner != find.owner {
            latestFriendFind = find
            for continuation in subscribers.values { continuation.yield(find) }
        }
        await refresh?(message.circleIDs)
    }

    /// The birder tapped a push.
    func opened(_ userInfo: [AnyHashable: Any]) async {
        let message = PushMessage(userInfo: userInfo)
        pendingCircle = message?.circleIDs.first ?? ""
        await received(userInfo)
    }

    /// Every notable find from now on, for the lens's friend banner (#67).
    func friendFinds() -> AsyncStream<FriendFind> {
        let id = UUID()
        return AsyncStream { continuation in
            subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.subscribers[id] = nil } }
        }
    }

    private func sendToken() async {
        guard let client, let token = deviceToken, account.isSignedIn, let subject = account.identity.subject else { return }
        if let registeredFor, registeredFor == (token, subject) { return }
        do {
            try await account.withAccessToken(doing: "turn on notifications") {
                try await client.registerDevice(token: token, environment: self.environment, accessToken: $0)
            }
            registeredFor = (token, subject)
        } catch {
            log.error("couldn't register the phone for pushes: \(String(describing: error))")
        }
    }

    private func unregister(accessToken: String) async {
        registeredFor = nil
        guard let client, let token = deviceToken else { return }
        do {
            try await client.unregisterDevice(token: token, accessToken: accessToken)
        } catch {
            log.error("couldn't take the phone off the account: \(String(describing: error))")
        }
    }
}

extension PushCenter {
    /// The app's push center over the system's permission and APNs registration. In debug builds
    /// `-fakePushPermission notDetermined|denied|authorized` answers for the system (`-fakePushGrant NO` makes the
    /// prompt deny), so the UI tests can tap through the explanation.
    ///
    /// With the fake circle server (`-fakeCircles`, `-fakeAccount`) and no `-fakePushPermission`, notifications count as
    /// allowed, so the other UI tests never meet the explanation or the system prompt. Under any fake, whether the
    /// explanation was shown lasts one launch only.
    static func forApp(account: AccountSession, client: CircleClient?, register: @escaping () -> Void) -> PushCenter {
        var authorizer: NotificationAuthorizing = SystemNotificationAuthorizer()
        var store = UserDefaults.standard
        #if DEBUG
        let defaults = UserDefaults.standard
        let fakeServer = defaults.string(forKey: "fakeCircles") != nil || defaults.string(forKey: "fakeAccount") != nil
        if let raw = defaults.string(forKey: "fakePushPermission") ?? (fakeServer ? "authorized" : nil) {
            let start: PushPermission = switch raw { case "denied": .denied; case "authorized": .authorized; default: .notDetermined }
            authorizer = FakeNotificationAuthorizer(permission: start, grants: defaults.object(forKey: "fakePushGrant") == nil || defaults.bool(forKey: "fakePushGrant"))
            store = UserDefaults(suiteName: "fake-push-\(UUID().uuidString)") ?? .standard
        }
        #endif
        return PushCenter(account: account, client: client, authorizer: authorizer, defaults: store, registerForRemoteNotifications: register)
    }
}

#if DEBUG
/// Answers for the system's permission in the tests and UI tests: starts at `permission`, and the prompt grants or
/// denies as told.
final class FakeNotificationAuthorizer: NotificationAuthorizing {
    private(set) var current: PushPermission
    let grants: Bool
    private(set) var requests = 0

    init(permission: PushPermission, grants: Bool = true) {
        current = permission
        self.grants = grants
    }

    func permission() async -> PushPermission { current }

    func request() async -> Bool {
        requests += 1
        guard current == .notDetermined else { return current == .authorized }
        current = grants ? .authorized : .denied
        return grants
    }
}
#endif
