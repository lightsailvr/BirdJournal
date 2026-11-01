#if DEBUG
import Foundation

/// The debug fake account (`-fakeAccount signedOut|signedIn`): sign-in succeeds at once as "Pat Birder", and the API
/// keeps the account in memory. Nothing leaves the phone.
enum FakeAccount {
    static func session(signedIn: Bool) -> AccountSession {
        let tokens = signedIn ? FakeAuthClient.tokens() : nil
        return AccountSession(auth: FakeAuthClient(), api: FakeAccountAPI(), store: InMemoryTokenStore(tokens))
    }
}

final class FakeAuthClient: AuthClient {
    func signIn(with provider: IdentityProvider) async throws -> AuthTokens { Self.tokens() }
    func refresh(_ tokens: AuthTokens) async throws -> AuthTokens { Self.tokens() }
    func revoke(_ tokens: AuthTokens) async {}

    static func tokens() -> AuthTokens {
        let claims = #"{"sub":"fake-sub","name":"Pat Birder","email":"pat@example.com"}"#
        let idToken = "e30.\(Data(claims.utf8).base64URLEncodedString()).sig"
        return AuthTokens(accessToken: "fake-access", idToken: idToken, refreshToken: "fake-refresh", expiresAt: .now.addingTimeInterval(3600))
    }
}

final class FakeAccountAPI: AccountAPI {
    private var account = Account(id: "fake-sub", displayName: nil, createdAt: .now)

    func account(accessToken: String) async throws -> Account { account }

    func setDisplayName(_ name: String, accessToken: String) async throws -> Account {
        account.displayName = name
        return account
    }
}
#endif
