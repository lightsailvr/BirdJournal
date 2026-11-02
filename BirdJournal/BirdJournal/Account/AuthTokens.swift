import Foundation

/// The two ways to sign in (spec v2, "Accounts"). The raw value is Cognito's identity provider name, so the hosted UI
/// goes straight to the provider's own page.
enum IdentityProvider: String, CaseIterable, Identifiable {
    case apple = "SignInWithApple"
    case google = "Google"

    var id: String { rawValue }
    var buttonTitle: String {
        switch self {
        case .apple: "Sign in with Apple"
        case .google: "Sign in with Google"
        }
    }
}

/// The user pool's tokens, kept in the Keychain. The access token is what the API takes; the refresh token renews it
/// at the token endpoint; the ID token only carries the name and email the app shows.
struct AuthTokens: Codable, Equatable {
    var accessToken: String
    var idToken: String
    var refreshToken: String
    var expiresAt: Date

    /// A minute's margin, so a token never expires between the check and the request.
    func needsRefresh(now: Date) -> Bool { now.addingTimeInterval(60) >= expiresAt }

    /// What the ID token says about the birder. Read without verifying: it only fills the screen, and the server
    /// checks the access token itself.
    var identity: Identity { Identity(idToken: idToken) }

    struct Identity: Equatable {
        var name: String?
        var email: String?
        /// The account's `sub`, the server's account id: whose finds the outbox is holding (issue #62).
        var subject: String?
        /// Signed in with Apple: the user pool's username for an Apple user is `signinwithapple_<id>` (issue #71).
        var isApple = false

        init(name: String? = nil, email: String? = nil, subject: String? = nil, isApple: Bool = false) {
            self.name = name
            self.email = email
            self.subject = subject
            self.isApple = isApple
        }

        init(idToken: String) {
            let parts = idToken.split(separator: ".")
            guard parts.count == 3, let payload = Data(base64URLEncoded: String(parts[1])),
                  let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
                self.init()
                return
            }
            let name = (claims["name"] as? String) ?? (claims["given_name"] as? String)
            self.init(
                name: name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                email: (claims["email"] as? String)?.nilIfEmpty,
                subject: (claims["sub"] as? String)?.nilIfEmpty,
                isApple: ((claims["cognito:username"] as? String) ?? "").lowercased().hasPrefix("signinwithapple_")
            )
        }
    }
}

extension Data {
    init?(base64URLEncoded string: String) {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
