import Foundation
import Testing
@testable import BirdJournal

// Issue #71: deleting the account, and reports and blocks. The API is answered by the tests.

private let base = URL(string: "https://api.example.com")!
private let start = Date(timeIntervalSince1970: 1_793_525_400)

private func respond(_ status: Int, _ json: String = "") -> (Data, URLResponse) {
    (Data(json.utf8), HTTPURLResponse(url: base, statusCode: status, httpVersion: nil, headerFields: nil)!)
}

/// Records the requests and answers them in order.
private final class Answers: @unchecked Sendable {
    var responses: [(Data, URLResponse)] = []
    var requests: [URLRequest] = []

    var transport: HTTPTransport {
        { request in
            self.requests.append(request)
            return self.responses.isEmpty ? respond(500) : self.responses.removeFirst()
        }
    }
}

private func signedInTokens(username: String) -> AuthTokens {
    let claims = ["sub": "sub-1", "email": "ada@example.com", "cognito:username": username]
    let payload = try! JSONSerialization.data(withJSONObject: claims, options: .sortedKeys)
    return AuthTokens(accessToken: "access-1", idToken: "e30.\(payload.base64URLEncodedString()).sig", refreshToken: "refresh-1", expiresAt: start.addingTimeInterval(3600))
}

private final class NoAuth: AuthClient {
    var revoked = 0
    func signIn(with provider: IdentityProvider) async throws -> AuthTokens { signedInTokens(username: "google_1") }
    func refresh(_ tokens: AuthTokens) async throws -> AuthTokens { tokens }
    func revoke(_ tokens: AuthTokens) async { revoked += 1 }
}

private final class AppleSheet: AppleReauthorizing {
    var answer: Result<String?, Error> = .success("apple-code")
    var asked = 0
    func authorizationCode() async throws -> String? {
        asked += 1
        return try answer.get()
    }
}

private struct SheetBroke: Error {}

@Suite("Deleting the account")
@MainActor
struct AccountDeletionTests {
    private func session(username: String, answers: Answers, apple: AppleSheet = AppleSheet(), auth: NoAuth = NoAuth(), store: InMemoryTokenStore? = nil) -> AccountSession {
        AccountSession(
            auth: auth, api: HTTPAccountAPI(baseURL: base, transport: answers.transport),
            store: store ?? InMemoryTokenStore(signedInTokens(username: username)), apple: apple, now: { start }
        )
    }

    @Test("an Apple account asks Apple once more and sends the code with the delete, then signs out")
    func apple() async throws {
        let answers = Answers()
        answers.responses = [respond(200, #"{"id":"sub-1","display_name":"Ada","created_at":"2026-11-01T09:30:00Z","provider":"apple"}"#), respond(204)]
        let apple = AppleSheet()
        let auth = NoAuth()
        let store = InMemoryTokenStore(signedInTokens(username: "signinwithapple_1"))
        let session = session(username: "signinwithapple_1", answers: answers, apple: apple, auth: auth, store: store)
        #expect(await session.deleteAccount())
        #expect(apple.asked == 1)
        let delete = try #require(answers.requests.last)
        #expect(delete.httpMethod == "DELETE")
        #expect(delete.url?.absoluteString == "https://api.example.com/v1/account")
        #expect(delete.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
        let body = try JSONDecoder().decode([String: String].self, from: delete.httpBody ?? Data())
        #expect(body == ["apple_authorization_code": "apple-code"])
        #expect(session.status == .signedOut)
        #expect(store.tokens == nil)
        #expect(session.deletedNotice != nil)
        // The user is gone at Cognito: nothing left to revoke.
        #expect(auth.revoked == 0)
    }

    @Test("a Google account deletes without Apple's sheet and with no body")
    func google() async throws {
        let answers = Answers()
        answers.responses = [respond(200, #"{"id":"sub-1","display_name":"Ada","created_at":"2026-11-01T09:30:00Z","provider":"google"}"#), respond(204)]
        let apple = AppleSheet()
        let session = session(username: "google_1", answers: answers, apple: apple)
        #expect(await session.deleteAccount())
        #expect(apple.asked == 0)
        #expect(answers.requests.last?.httpBody == nil)
    }

    @Test("a cancelled or failed Apple sheet still deletes")
    func appleSheetCancelled() async throws {
        for answer: Result<String?, Error> in [.success(nil), .failure(SheetBroke())] {
            let answers = Answers()
            answers.responses = [respond(200, #"{"id":"sub-1","created_at":"2026-11-01T09:30:00Z","provider":"apple"}"#), respond(204)]
            let apple = AppleSheet()
            apple.answer = answer
            let session = session(username: "signinwithapple_1", answers: answers, apple: apple)
            #expect(await session.deleteAccount())
            #expect(answers.requests.last?.httpBody == nil)
        }
    }

    @Test("a server error is tried twice more; three failures keep the account and say so")
    func retries() async throws {
        let answers = Answers()
        answers.responses = [respond(200, #"{"id":"sub-1","created_at":"2026-11-01T09:30:00Z","provider":"google"}"#), respond(503), respond(204)]
        let ok = session(username: "google_1", answers: answers)
        #expect(await ok.deleteAccount())
        #expect(answers.requests.filter { $0.httpMethod == "DELETE" }.count == 2)

        let failing = Answers()
        failing.responses = [respond(200, #"{"id":"sub-1","created_at":"2026-11-01T09:30:00Z","provider":"google"}"#), respond(503), respond(503), respond(503)]
        let session = session(username: "google_1", answers: failing)
        #expect(await session.deleteAccount() == false)
        #expect(session.status == .signedIn)
        #expect(session.errorMessage == "Couldn't delete your account. Check your connection and try again.")
    }

    @Test("the ID token's username says whether the account signs in with Apple")
    func appleIdentity() {
        #expect(signedInTokens(username: "signinwithapple_000").identity.isApple)
        #expect(signedInTokens(username: "SignInWithApple_000").identity.isApple)
        #expect(!signedInTokens(username: "google_1").identity.isApple)
    }

    @Test("the alert says what goes, and that Apple will ask for an Apple account")
    func warning() {
        #expect(AccountView.deletionWarning(apple: false).contains("can't be undone"))
        #expect(!AccountView.deletionWarning(apple: false).contains("Apple"))
        #expect(AccountView.deletionWarning(apple: true).contains("Apple will ask"))
    }
}

@Suite("Reports and blocks")
@MainActor
struct ReportAndBlockTests {
    @Test("a find's report posts what it names, without empty details")
    func reportFind() async throws {
        let answers = Answers()
        answers.responses = [respond(201, #"{"id":"r1","created_at":"2026-11-01T09:30:00Z"}"#)]
        let client = HTTPCircleClient(baseURL: base, transport: answers.transport)
        var draft = ReportDraft(kind: .find, accountID: "maya", circleID: "c1", sightingID: "s-1", reason: .spam)
        draft.details = "   "
        try await client.report(draft.sent, accessToken: "t-1")
        let request = try #require(answers.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.example.com/v1/reports")
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String])
        #expect(body == ["kind": "find", "account_id": "maya", "circle_id": "c1", "sighting_id": "s-1", "reason": "spam"])
    }

    @Test("a member's report has no sighting, and a full day's reports say so")
    func reportAccount() async throws {
        let answers = Answers()
        answers.responses = [respond(201, "{}"), respond(429, #"{"detail":"too_many_reports"}"#), respond(422, #"{"detail":"own_account"}"#)]
        let client = HTTPCircleClient(baseURL: base, transport: answers.transport)
        let draft = ReportDraft(kind: .account, accountID: "maya", circleID: "c1", reason: .harassment, details: "Rude")
        try await client.report(draft, accessToken: "t")
        let body = try #require(try JSONSerialization.jsonObject(with: answers.requests[0].httpBody ?? Data()) as? [String: String])
        #expect(body == ["kind": "account", "account_id": "maya", "circle_id": "c1", "reason": "harassment", "details": "Rude"])
        await #expect(throws: CircleError.tooManyReports) { try await client.report(draft, accessToken: "t") }
        await #expect(throws: CircleError.ownAccount) { try await client.report(draft, accessToken: "t") }
    }

    @Test("blocks list, block and unblock")
    func blocks() async throws {
        let answers = Answers()
        answers.responses = [respond(200, #"{"accounts":[{"id":"maya","display_name":"Maya Ortiz"},{"id":"x","display_name":null}]}"#), respond(204), respond(204)]
        let client = HTTPCircleClient(baseURL: base, transport: answers.transport)
        let blocked = try await client.blocks(accessToken: "t")
        #expect(blocked == [BlockedAccount(id: "maya", displayName: "Maya Ortiz"), BlockedAccount(id: "x", displayName: nil)])
        #expect(blocked[1].name == "A birder")
        try await client.setBlocked(true, accountID: "maya", accessToken: "t")
        try await client.setBlocked(false, accountID: "maya", accessToken: "t")
        #expect(answers.requests.map { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")" } == ["GET /v1/blocks", "PUT /v1/blocks/maya", "DELETE /v1/blocks/maya"])
    }

    @Test("blocking over the fake hides the account's finds from the feed and lists them; unblocking brings them back")
    func blockHidesFinds() async throws {
        let account = FakeAccount.session(signedIn: true)
        let store = CircleStore(account: account, client: FakeCircleClient(seeded: true), timeZone: { "Europe/London" })
        await store.refresh()
        let sunday = try #require(store.circles.first { $0.name == "Sunday Group" })
        await store.loadFeed(circleID: sunday.id)
        #expect(store.feeds[sunday.id]?.items.contains { $0.owner.id == "maya" } == true)
        try await store.setBlocked(true, accountID: "maya", name: "Maya Ortiz")
        #expect(store.feeds[sunday.id]?.items.contains { $0.owner.id == "maya" } == false)
        #expect(store.blocked.map(\.id) == ["maya"])
        try await store.setBlocked(false, accountID: "maya", name: "Maya Ortiz")
        #expect(store.feeds[sunday.id]?.items.contains { $0.owner.id == "maya" } == true)
        #expect(store.blocked.isEmpty)
    }

    @Test("over the fake a report needs someone in the circle, never oneself")
    func fakeReport() async throws {
        let account = FakeAccount.session(signedIn: true)
        let store = CircleStore(account: account, client: FakeCircleClient(seeded: true), timeZone: { "Europe/London" })
        await store.refresh()
        let sunday = try #require(store.circles.first { $0.name == "Sunday Group" })
        try await store.report(ReportDraft(kind: .account, accountID: "maya", circleID: sunday.id))
        await #expect(throws: CircleError.notFound) {
            try await store.report(ReportDraft(kind: .account, accountID: "nobody", circleID: sunday.id))
        }
    }
}
