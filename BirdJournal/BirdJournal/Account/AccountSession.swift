import Foundation
import Observation
import OSLog

/// The optional account (issue #60): signed out, signing in through Apple or Google, or signed in with tokens in the
/// Keychain that survive a relaunch. Nothing else in the app waits on it: listening, the journal, cards and packs work
/// signed out, and signing out only forgets the tokens, never the journal or the cards.
@Observable
final class AccountSession {
    enum Status: Equatable {
        /// This build has no account server (the stack isn't deployed yet).
        case unavailable
        case signedOut
        case signingIn(IdentityProvider)
        case signedIn
    }

    private(set) var status: Status
    /// The server's account, once read; nil while signed out or before the first read.
    private(set) var account: Account?
    /// What the ID token says: the email to show, and a name to offer the server when the account has none.
    private(set) var identity = AuthTokens.Identity()
    /// The last thing that went wrong, in words for the Account screen.
    private(set) var errorMessage: String?

    private let auth: AuthClient?
    private let api: AccountAPI?
    private let store: TokenStore
    private let now: () -> Date
    private var tokens: AuthTokens?
    /// One refresh at a time: concurrent callers wait for the same renewal.
    private var refreshing: Task<AuthTokens, Error>?
    private let log = Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "account")

    init(auth: AuthClient?, api: AccountAPI?, store: TokenStore, now: @escaping () -> Date = Date.init) {
        self.auth = auth
        self.api = api
        self.store = store
        self.now = now
        guard auth != nil, api != nil else {
            status = .unavailable
            return
        }
        let saved = store.load()
        status = saved == nil ? .signedOut : .signedIn
        tokens = saved
        identity = saved?.identity ?? .init()
    }

    var isSignedIn: Bool { status == .signedIn }

    /// Signs in through the provider's page, keeps the tokens and reads (so creates) the account. The first time, the
    /// account takes the provider's name, which the birder can change.
    func signIn(with provider: IdentityProvider) async {
        guard let auth, status == .signedOut else { return }
        status = .signingIn(provider)
        errorMessage = nil
        do {
            let tokens = try await auth.signIn(with: provider)
            try store.save(tokens)
            self.tokens = tokens
            identity = tokens.identity
            status = .signedIn
        } catch AuthError.cancelled {
            status = .signedOut
            return
        } catch {
            log.error("sign-in failed: \(String(describing: error))")
            status = .signedOut
            errorMessage = "Couldn't sign in. Check your connection and try again."
            return
        }
        await loadAccount()
        if let account, account.displayName == nil, let name = identity.name {
            await setDisplayName(name)
        }
    }

    /// Reads the account from the server (creating it on the first call).
    func loadAccount() async {
        guard let api else { return }
        do {
            let account = try await authorized { try await api.account(accessToken: $0) }
            self.account = account
            errorMessage = nil
        } catch {
            report(error, doing: "load your account")
        }
    }

    func setDisplayName(_ name: String) async {
        guard let api else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            account = try await authorized { try await api.setDisplayName(trimmed, accessToken: $0) }
            errorMessage = nil
        } catch AccountAPIError.rejected {
            errorMessage = "Use a name of up to 40 characters, on one line."
        } catch {
            report(error, doing: "save your name")
        }
    }

    /// Forgets the tokens here and revokes the refresh token at Cognito. The journal and cards stay on the phone.
    func signOut() {
        let revoked = tokens
        tokens = nil
        refreshing = nil
        store.clear()
        account = nil
        identity = .init()
        errorMessage = nil
        if status != .unavailable { status = .signedOut }
        if let revoked, let auth { Task { await auth.revoke(revoked) } }
    }

    /// An access token good for at least another minute, renewed at the token endpoint when it isn't.
    func validAccessToken() async throws -> String {
        guard let tokens else { throw AuthError.sessionExpired }
        if tokens.needsRefresh(now: now()) { return try await renew().accessToken }
        return tokens.accessToken
    }

    /// Runs another part of the API (circles, issue #61) with the account's token, renewed the same way. A revoked
    /// refresh token signs out with the same message as the account's own calls.
    func withAccessToken<T>(_ call: (String) async throws -> T) async throws -> T {
        do {
            return try await authorized(call)
        } catch AuthError.sessionExpired {
            report(AuthError.sessionExpired, doing: "reach your circles")
            throw AuthError.sessionExpired
        }
    }

    /// Runs a call with a valid access token; a 401 renews the token once and retries.
    private func authorized<T>(_ call: (String) async throws -> T) async throws -> T {
        do {
            return try await call(try await validAccessToken())
        } catch AccountAPIError.unauthorized {
            return try await call(try await renew().accessToken)
        } catch CircleError.unauthorized {
            return try await call(try await renew().accessToken)
        }
    }

    private func renew() async throws -> AuthTokens {
        if let refreshing { return try await refreshing.value }
        guard let auth, let current = tokens else { throw AuthError.sessionExpired }
        let task = Task { try await auth.refresh(current) }
        refreshing = task
        defer { refreshing = nil }
        let renewed = try await task.value
        // Signed out, or out and in again, while the renewal was in flight: drop it and use what is current.
        guard tokens == current else {
            if let tokens { return tokens }
            throw AuthError.sessionExpired
        }
        try store.save(renewed)
        tokens = renewed
        return renewed
    }

    private func report(_ error: Error, doing action: String) {
        if case AuthError.sessionExpired = error {
            signOut()
            errorMessage = "You've been signed out. Sign in again to use your account."
            return
        }
        log.error("couldn't \(action): \(String(describing: error))")
        errorMessage = "Couldn't \(action). Check your connection and try again."
    }
}

extension AccountSession {
    /// The app's session: the bundled server with the system browser sheet and the Keychain, or `.unavailable` when
    /// the build has no server yet. In debug builds `-fakeAccount signedOut|signedIn` swaps in a fake client and API
    /// with tokens in memory, so the UI tests can tap through sign-in with no network.
    static func forApp() -> AccountSession {
        #if DEBUG
        if let mode = UserDefaults.standard.string(forKey: "fakeAccount") {
            return FakeAccount.session(signedIn: mode == "signedIn")
        }
        #endif
        guard let server = AccountServer.bundled() else {
            return AccountSession(auth: nil, api: nil, store: InMemoryTokenStore())
        }
        let store = KeychainTokenStore()
        forgetTokensFromAPreviousInstall(store)
        return AccountSession(
            auth: CognitoAuthClient(server: server, web: SystemWebSignIn()),
            api: HTTPAccountAPI(baseURL: server.apiURL),
            store: store
        )
    }

    /// Keychain items outlive deleting the app; a reinstall starts signed out, as a birder would expect.
    private static func forgetTokensFromAPreviousInstall(_ store: TokenStore) {
        let key = "accountKeychainClearedAfterInstall"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        store.clear()
        UserDefaults.standard.set(true, forKey: key)
    }
}
