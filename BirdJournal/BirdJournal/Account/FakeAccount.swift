#if DEBUG
import Foundation

/// The debug fake account (`-fakeAccount signedOut|signedIn`): sign-in succeeds at once as "Pat Birder", and the API
/// keeps the account in memory. Nothing leaves the phone.
enum FakeAccount {
    static func session(signedIn: Bool) -> AccountSession {
        let tokens = signedIn ? FakeAuthClient.tokens() : nil
        return AccountSession(
            auth: FakeAuthClient(), api: FakeAccountAPI(), store: InMemoryTokenStore(tokens), apple: FakeAppleReauthorization()
        )
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
    private var account = Account(id: "fake-sub", displayName: nil, createdAt: .now, provider: "apple")
    /// What `deleteAccount` was given (issue #71): the Apple code, or "none".
    private(set) var deletions: [String] = []
    /// `-fakeAccountDeletion fails` makes deleting fail, for the error path.
    var deletionFails = UserDefaults.standard.string(forKey: "fakeAccountDeletion") == "fails"

    func account(accessToken: String) async throws -> Account { account }

    func deleteAccount(appleAuthorizationCode: String?, accessToken: String) async throws {
        if deletionFails { throw AccountAPIError.server(503) }
        deletions.append(appleAuthorizationCode ?? "none")
        account = Account(id: "fake-sub", displayName: nil, createdAt: .now, provider: "apple")
    }

    func setDisplayName(_ name: String, accessToken: String) async throws -> Account {
        account.displayName = name
        return account
    }
}
/// Apple's sheet, answered at once (`-fakeAppleReauthorization cancel` cancels it).
final class FakeAppleReauthorization: AppleReauthorizing {
    func authorizationCode() async throws -> String? {
        UserDefaults.standard.string(forKey: "fakeAppleReauthorization") == "cancel" ? nil : "fake-apple-code"
    }
}
#endif
