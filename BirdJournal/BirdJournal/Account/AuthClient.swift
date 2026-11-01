import AuthenticationServices
import Foundation
import UIKit

enum AuthError: Error, Equatable {
    /// The birder closed the sign-in sheet: not a failure to report.
    case cancelled
    /// The provider or Cognito turned the sign-in down (`error` on the callback), or the callback was not ours.
    case refused(String)
    /// The refresh token was revoked or expired: the birder has to sign in again.
    case sessionExpired
    /// The token endpoint answered something other than tokens.
    case badResponse(Int)
}

/// Signs in, renews and revokes the user pool's tokens.
protocol AuthClient: AnyObject {
    func signIn(with provider: IdentityProvider) async throws -> AuthTokens
    func refresh(_ tokens: AuthTokens) async throws -> AuthTokens
    func revoke(_ tokens: AuthTokens) async
}

/// Shows a URL in a browser sheet and returns the callback URL it ends on.
protocol WebSignIn: AnyObject {
    func callbackURL(for url: URL, scheme: String) async throws -> URL
}

/// Sends one request; the tests answer it themselves.
typealias HTTPTransport = (URLRequest) async throws -> (Data, URLResponse)

/// The user pool's hosted endpoints without Amplify (spec v2): the authorization code grant with PKCE in
/// ASWebAuthenticationSession, then the token endpoint for the tokens and their renewal.
final class CognitoAuthClient: AuthClient {
    private let server: AccountServer
    private let web: WebSignIn
    private let transport: HTTPTransport
    private let now: () -> Date
    private let makePKCE: () -> PKCE
    private let makeState: () -> String

    init(
        server: AccountServer,
        web: WebSignIn,
        transport: @escaping HTTPTransport = { try await URLSession.shared.data(for: $0) },
        now: @escaping () -> Date = Date.init,
        makePKCE: @escaping () -> PKCE = { PKCE.random() },
        makeState: @escaping () -> String = { PKCE.random().verifier }
    ) {
        self.server = server
        self.web = web
        self.transport = transport
        self.now = now
        self.makePKCE = makePKCE
        self.makeState = makeState
    }

    func signIn(with provider: IdentityProvider) async throws -> AuthTokens {
        let pkce = makePKCE()
        let state = makeState()
        let callback = try await web.callbackURL(for: authorizeURL(provider: provider, pkce: pkce, state: state), scheme: AccountServer.callbackScheme)
        let code = try Self.code(from: callback, state: state)
        let response = try await tokenRequest([
            "grant_type": "authorization_code",
            "client_id": server.clientID,
            "code": code,
            "redirect_uri": AccountServer.redirectURI,
            "code_verifier": pkce.verifier,
        ])
        guard let refreshToken = response.refresh_token else { throw AuthError.badResponse(200) }
        return AuthTokens(accessToken: response.access_token, idToken: response.id_token, refreshToken: refreshToken, expiresAt: now().addingTimeInterval(response.expires_in))
    }

    func refresh(_ tokens: AuthTokens) async throws -> AuthTokens {
        let response = try await tokenRequest([
            "grant_type": "refresh_token",
            "client_id": server.clientID,
            "refresh_token": tokens.refreshToken,
        ])
        // Cognito returns a new refresh token only with rotation on; otherwise the old one stays good.
        return AuthTokens(
            accessToken: response.access_token, idToken: response.id_token,
            refreshToken: response.refresh_token ?? tokens.refreshToken,
            expiresAt: now().addingTimeInterval(response.expires_in)
        )
    }

    func revoke(_ tokens: AuthTokens) async {
        _ = try? await transport(Self.formPost(server.revokeURL, ["token": tokens.refreshToken, "client_id": server.clientID]))
    }

    func authorizeURL(provider: IdentityProvider, pkce: PKCE, state: String) -> URL {
        var components = URLComponents(url: server.authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: server.clientID),
            URLQueryItem(name: "redirect_uri", value: AccountServer.redirectURI),
            URLQueryItem(name: "identity_provider", value: provider.rawValue),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return components.url!
    }

    /// The authorization code on our callback, after checking it answers this sign-in.
    static func code(from callback: URL, state: String) throws -> String {
        let expected = URLComponents(string: AccountServer.redirectURI)!
        guard let components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              components.scheme == expected.scheme, components.host == expected.host, components.path == expected.path else {
            throw AuthError.refused("unexpected callback")
        }
        let items = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        if let error = items["error"] { throw AuthError.refused(items["error_description"] ?? error) }
        guard items["state"] == state else { throw AuthError.refused("state mismatch") }
        guard let code = items["code"], !code.isEmpty else { throw AuthError.refused("no code") }
        return code
    }

    private struct TokenResponse: Decodable {
        var access_token: String
        var id_token: String
        var refresh_token: String?
        var expires_in: TimeInterval
    }

    private func tokenRequest(_ fields: [String: String]) async throws -> TokenResponse {
        let (data, response) = try await transport(Self.formPost(server.tokenURL, fields))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 400, let error = try? JSONDecoder().decode([String: String].self, from: data), error["error"] == "invalid_grant" {
            throw AuthError.sessionExpired
        }
        guard status == 200, let tokens = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw AuthError.badResponse(status)
        }
        return tokens
    }

    static func formPost(_ url: URL, _ fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(fields)
        return request
    }

    static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)!
    }
}

/// ASWebAuthenticationSession over the key window, ephemeral so the hosted UI keeps no cookie: signing out and in
/// again can pick another Apple ID or Google account.
final class SystemWebSignIn: NSObject, WebSignIn, ASWebAuthenticationPresentationContextProviding {
    /// Held while the sheet is up: a session nobody holds can be released and never call back.
    private var session: ASWebAuthenticationSession?

    func callbackURL(for url: URL, scheme: String) async throws -> URL {
        defer { self.session = nil }
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(scheme)) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: AuthError.cancelled)
                } else {
                    continuation.resume(throwing: error ?? AuthError.refused("no callback"))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            self.session = session
            if !session.start() { continuation.resume(throwing: AuthError.refused("the sign-in sheet did not open")) }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) { return window }
        if let scene = scenes.first { return ASPresentationAnchor(windowScene: scene) }
        return ASPresentationAnchor()
    }
}
