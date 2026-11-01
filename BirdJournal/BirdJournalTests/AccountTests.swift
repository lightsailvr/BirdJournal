import Foundation
import Testing
@testable import BirdJournal

// Issue #60: the optional account. Cognito's endpoints and the API are answered by the tests; the browser sheet is a
// stand-in that returns the callback a real sign-in would.

private let server = AccountServer(apiURL: URL(string: "https://api.example.com")!, cognitoDomain: "auth.example.com", clientID: "ios-client")
private let start = Date(timeIntervalSince1970: 1_793_525_400)

private func idToken(_ claims: [String: String]) -> String {
    let payload = try! JSONSerialization.data(withJSONObject: claims, options: .sortedKeys)
    return "e30.\(payload.base64URLEncodedString()).sig"
}

private func tokens(access: String = "access-1", refresh: String = "refresh-1", expiresAt: Date = start.addingTimeInterval(3600), name: String? = "Ada Lovelace") -> AuthTokens {
    var claims = ["sub": "sub-1", "email": "ada@example.com"]
    claims["name"] = name
    return AuthTokens(accessToken: access, idToken: idToken(claims), refreshToken: refresh, expiresAt: expiresAt)
}

private func http(_ status: Int, _ json: String) -> (Data, URLResponse) {
    (Data(json.utf8), HTTPURLResponse(url: URL(string: "https://x")!, statusCode: status, httpVersion: nil, headerFields: nil)!)
}

private func formFields(_ request: URLRequest) -> [String: String] {
    let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    return Dictionary(uniqueKeysWithValues: body.split(separator: "&").map {
        let pair = $0.split(separator: "=", maxSplits: 1).map(String.init)
        return (pair[0], pair[1].removingPercentEncoding ?? pair[1])
    })
}

/// The browser sheet: remembers the URL it was shown and answers with the callback the test chose.
private final class StubWebSignIn: WebSignIn {
    var shown: URL?
    var answer: (URL) throws -> URL

    init(answer: @escaping (URL) throws -> URL) { self.answer = answer }

    func callbackURL(for url: URL, scheme: String) async throws -> URL {
        shown = url
        return try answer(url)
    }
}

/// Answers the token endpoint and records each request.
private final class Recorder {
    var requests: [URLRequest] = []
    var responses: [(Data, URLResponse)] = []

    func transport(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        return responses.isEmpty ? http(500, "{}") : responses.removeFirst()
    }
}

@Suite("Cognito sign-in without Amplify")
struct CognitoAuthClientTests {
    @Test("the S256 challenge matches RFC 7636's example")
    func pkce() {
        #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(PKCE.random().verifier.count == 43)
        #expect(PKCE.random() != PKCE.random())
    }

    @Test("the authorize URL goes straight to the provider with the PKCE challenge and our callback")
    func authorizeURL() throws {
        let client = CognitoAuthClient(server: server, web: StubWebSignIn { $0 })
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let url = client.authorizeURL(provider: .apple, pkce: pkce, state: "state-1")
        let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        #expect(url.absoluteString.hasPrefix("https://auth.example.com/oauth2/authorize?"))
        #expect(items == [
            "response_type": "code", "client_id": "ios-client", "redirect_uri": "birdjournal://auth/callback",
            "identity_provider": "SignInWithApple", "scope": "openid email profile", "state": "state-1",
            "code_challenge": "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "code_challenge_method": "S256",
        ])
        #expect(client.authorizeURL(provider: .google, pkce: pkce, state: "s").absoluteString.contains("identity_provider=Google"))
    }

    @Test("a sign-in exchanges the code and the verifier for tokens that expire when the endpoint says")
    func signIn() async throws {
        let recorder = Recorder()
        recorder.responses = [http(200, #"{"access_token":"a","id_token":"i","refresh_token":"r","expires_in":3600,"token_type":"Bearer"}"#)]
        let web = StubWebSignIn { _ in URL(string: "birdjournal://auth/callback?code=code-1&state=state-1")! }
        let client = CognitoAuthClient(server: server, web: web, transport: recorder.transport, now: { start }, makePKCE: { PKCE(verifier: "verifier-1") }, makeState: { "state-1" })

        let tokens = try await client.signIn(with: .google)

        #expect(tokens == AuthTokens(accessToken: "a", idToken: "i", refreshToken: "r", expiresAt: start.addingTimeInterval(3600)))
        let request = try #require(recorder.requests.first)
        #expect(request.url == server.tokenURL)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(formFields(request) == [
            "grant_type": "authorization_code", "client_id": "ios-client", "code": "code-1",
            "redirect_uri": "birdjournal://auth/callback", "code_verifier": "verifier-1",
        ])
    }

    @Test("a callback for another sign-in, or with an error, is refused before any token request")
    func callbacks() throws {
        #expect(throws: AuthError.refused("state mismatch")) {
            try CognitoAuthClient.code(from: URL(string: "birdjournal://auth/callback?code=c&state=other")!, state: "mine")
        }
        #expect(throws: AuthError.refused("User cancelled")) {
            try CognitoAuthClient.code(from: URL(string: "birdjournal://auth/callback?error=access_denied&error_description=User%20cancelled&state=mine")!, state: "mine")
        }
        #expect(throws: AuthError.refused("unexpected callback")) {
            try CognitoAuthClient.code(from: URL(string: "birdjournal://other?code=c&state=mine")!, state: "mine")
        }
        #expect(throws: AuthError.refused("unexpected callback")) {
            try CognitoAuthClient.code(from: URL(string: "birdjournal://auth/callbackX?code=c&state=mine")!, state: "mine")
        }
        #expect(try CognitoAuthClient.code(from: URL(string: "birdjournal://auth/callback?code=c&state=mine")!, state: "mine") == "c")
    }

    @Test("a refresh keeps the refresh token when Cognito doesn't rotate it")
    func refresh() async throws {
        let recorder = Recorder()
        recorder.responses = [http(200, #"{"access_token":"a2","id_token":"i2","expires_in":3600,"token_type":"Bearer"}"#)]
        let client = CognitoAuthClient(server: server, web: StubWebSignIn { $0 }, transport: recorder.transport, now: { start })

        let renewed = try await client.refresh(tokens(refresh: "refresh-1"))

        #expect(renewed == AuthTokens(accessToken: "a2", idToken: "i2", refreshToken: "refresh-1", expiresAt: start.addingTimeInterval(3600)))
        #expect(formFields(recorder.requests[0]) == ["grant_type": "refresh_token", "client_id": "ios-client", "refresh_token": "refresh-1"])
    }

    @Test("a revoked or expired refresh token ends the session")
    func expiredRefresh() async {
        let recorder = Recorder()
        recorder.responses = [http(400, #"{"error":"invalid_grant"}"#)]
        let client = CognitoAuthClient(server: server, web: StubWebSignIn { $0 }, transport: recorder.transport)
        await #expect(throws: AuthError.sessionExpired) { try await client.refresh(tokens()) }
    }

    @Test("sign-out revokes the refresh token at Cognito")
    func revoke() async {
        let recorder = Recorder()
        recorder.responses = [http(200, "")]
        let client = CognitoAuthClient(server: server, web: StubWebSignIn { $0 }, transport: recorder.transport)
        await client.revoke(tokens(refresh: "refresh-9"))
        #expect(recorder.requests.first?.url == server.revokeURL)
        #expect(formFields(recorder.requests[0]) == ["token": "refresh-9", "client_id": "ios-client"])
    }

    @Test("the bundled settings are unavailable until a deploy fills them in")
    func serverSettings() {
        #expect(AccountServer.decode(Data(#"{"apiURL":"","cognitoDomain":"","clientID":""}"#.utf8)) == nil)
        #expect(AccountServer.decode(Data(#"{"apiURL":"https://api.example.com","cognitoDomain":"auth.example.com","clientID":"ios-client"}"#.utf8)) == server)
    }

    @Test("the account decodes from the API's JSON")
    func accountJSON() async throws {
        let recorder = Recorder()
        recorder.responses = [http(200, #"{"id":"sub-1","display_name":null,"created_at":"2026-11-01T09:30:00Z"}"#), http(401, "{}")]
        let api = HTTPAccountAPI(baseURL: server.apiURL, transport: recorder.transport)
        let account = try await api.account(accessToken: "token-1")
        #expect(account == Account(id: "sub-1", displayName: nil, createdAt: start))
        #expect(recorder.requests[0].url?.absoluteString == "https://api.example.com/v1/account")
        #expect(recorder.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer token-1")
        await #expect(throws: AccountAPIError.unauthorized) { try await api.setDisplayName("A", accessToken: "t") }
        #expect(recorder.requests[1].httpMethod == "PATCH")
    }
}

/// Signs in with whatever tokens the test sets, and records refreshes and revocations.
private final class FakeAuth: AuthClient {
    var signInResult: Result<AuthTokens, Error> = .success(tokens())
    var refreshResult: Result<AuthTokens, Error> = .success(tokens(access: "access-2"))
    var refreshed: [AuthTokens] = []
    var revoked: [AuthTokens] = []

    func signIn(with provider: IdentityProvider) async throws -> AuthTokens { try signInResult.get() }
    func refresh(_ tokens: AuthTokens) async throws -> AuthTokens {
        refreshed.append(tokens)
        return try refreshResult.get()
    }
    func revoke(_ tokens: AuthTokens) async { revoked.append(tokens) }
}

/// The server's account in memory; records the access token of every call and can refuse the first few.
private final class FakeAPI: AccountAPI {
    var stored: Account?
    var tokensSeen: [String] = []
    var refuseNext = 0

    func account(accessToken: String) async throws -> Account {
        try check(accessToken)
        if stored == nil { stored = Account(id: "sub-1", displayName: nil, createdAt: start) }
        return stored!
    }

    func setDisplayName(_ name: String, accessToken: String) async throws -> Account {
        try check(accessToken)
        stored = Account(id: "sub-1", displayName: name, createdAt: stored?.createdAt ?? start)
        return stored!
    }

    private func check(_ token: String) throws {
        tokensSeen.append(token)
        if refuseNext > 0 {
            refuseNext -= 1
            throw AccountAPIError.unauthorized
        }
    }
}

@Suite("The optional account")
@MainActor
struct AccountSessionTests {
    @Test("signing in keeps the tokens, creates the account and gives it the provider's name")
    func signIn() async {
        let store = InMemoryTokenStore()
        let api = FakeAPI()
        let session = AccountSession(auth: FakeAuth(), api: api, store: store, now: { start })
        #expect(session.status == .signedOut)

        await session.signIn(with: .apple)

        #expect(session.status == .signedIn)
        #expect(store.tokens == tokens())
        #expect(session.account?.displayName == "Ada Lovelace")
        #expect(session.identity.email == "ada@example.com")
    }

    @Test("a name the birder already chose is not overwritten at the next sign-in")
    func keepsChosenName() async {
        let api = FakeAPI()
        api.stored = Account(id: "sub-1", displayName: "Ada", createdAt: start)
        let session = AccountSession(auth: FakeAuth(), api: api, store: InMemoryTokenStore(), now: { start })
        await session.signIn(with: .google)
        #expect(session.account?.displayName == "Ada")
    }

    @Test("the tokens survive a relaunch")
    func relaunch() async {
        let store = InMemoryTokenStore()
        let first = AccountSession(auth: FakeAuth(), api: FakeAPI(), store: store, now: { start })
        await first.signIn(with: .apple)

        let relaunched = AccountSession(auth: FakeAuth(), api: FakeAPI(), store: store, now: { start })
        #expect(relaunched.status == .signedIn)
        #expect(relaunched.identity.email == "ada@example.com")
    }

    @Test("an expired access token is renewed at the token endpoint before the call, and the renewal is kept")
    func refreshBeforeCall() async {
        let store = InMemoryTokenStore(tokens(expiresAt: start.addingTimeInterval(30)))
        let auth = FakeAuth()
        let api = FakeAPI()
        let session = AccountSession(auth: auth, api: api, store: store, now: { start })

        await session.loadAccount()

        #expect(auth.refreshed.count == 1)
        #expect(api.tokensSeen == ["access-2"])
        #expect(store.tokens?.accessToken == "access-2")
        #expect(session.account != nil)
    }

    @Test("a refused access token is renewed once and the call retried")
    func retryOn401() async {
        let auth = FakeAuth()
        let api = FakeAPI()
        api.refuseNext = 1
        let session = AccountSession(auth: auth, api: api, store: InMemoryTokenStore(tokens()), now: { start })
        await session.loadAccount()
        #expect(api.tokensSeen == ["access-1", "access-2"])
        #expect(session.account != nil)
        #expect(session.errorMessage == nil)
    }

    @Test("a revoked refresh token signs the birder out and says so")
    func sessionExpired() async {
        let store = InMemoryTokenStore(tokens(expiresAt: start))
        let auth = FakeAuth()
        auth.refreshResult = .failure(AuthError.sessionExpired)
        let session = AccountSession(auth: auth, api: FakeAPI(), store: store, now: { start })

        await session.loadAccount()

        #expect(session.status == .signedOut)
        #expect(store.tokens == nil)
        #expect(session.errorMessage?.contains("signed out") == true)
    }

    @Test("signing out forgets the tokens here and revokes them at Cognito")
    func signOut() async {
        let store = InMemoryTokenStore()
        let auth = FakeAuth()
        let session = AccountSession(auth: auth, api: FakeAPI(), store: store, now: { start })
        await session.signIn(with: .apple)

        session.signOut()

        #expect(session.status == .signedOut)
        #expect(session.account == nil)
        #expect(store.tokens == nil)
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(auth.revoked.map(\.refreshToken) == ["refresh-1"])
    }

    @Test("closing the sign-in sheet is not an error")
    func cancelled() async {
        let auth = FakeAuth()
        auth.signInResult = .failure(AuthError.cancelled)
        let session = AccountSession(auth: auth, api: FakeAPI(), store: InMemoryTokenStore(), now: { start })
        await session.signIn(with: .google)
        #expect(session.status == .signedOut)
        #expect(session.errorMessage == nil)
    }

    @Test("a failed sign-in stays signed out with a message")
    func failed() async {
        let auth = FakeAuth()
        auth.signInResult = .failure(AuthError.badResponse(500))
        let store = InMemoryTokenStore()
        let session = AccountSession(auth: auth, api: FakeAPI(), store: store, now: { start })
        await session.signIn(with: .apple)
        #expect(session.status == .signedOut)
        #expect(store.tokens == nil)
        #expect(session.errorMessage != nil)
    }

    @Test("a name the server turns down keeps the old one and explains the limit")
    func rejectedName() async {
        final class RejectingAPI: AccountAPI {
            func account(accessToken: String) async throws -> Account { Account(id: "s", displayName: "Old", createdAt: start) }
            func setDisplayName(_ name: String, accessToken: String) async throws -> Account { throw AccountAPIError.rejected }
        }
        let session = AccountSession(auth: FakeAuth(), api: RejectingAPI(), store: InMemoryTokenStore(tokens()), now: { start })
        await session.loadAccount()
        await session.setDisplayName(String(repeating: "x", count: 41))
        #expect(session.account?.displayName == "Old")
        #expect(session.errorMessage == "Use a name of up to 40 characters, on one line.")
    }

    @Test("without an account server the build has no account, and nothing asks for one")
    func unavailable() async {
        let session = AccountSession(auth: nil, api: nil, store: InMemoryTokenStore(tokens()))
        #expect(session.status == .unavailable)
        await session.signIn(with: .apple)
        #expect(session.status == .unavailable)
    }
}
