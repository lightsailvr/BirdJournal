import CryptoKit
import Foundation

/// Proof Key for Code Exchange (RFC 7636): the public client's stand-in for a secret.
struct PKCE: Equatable {
    var verifier: String
    var challenge: String { Self.challenge(for: verifier) }

    /// 32 random bytes, base64url: a 43-character verifier.
    static func random() -> PKCE {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return PKCE(verifier: Data(bytes).base64URLEncodedString())
    }

    /// S256: base64url(SHA-256(verifier)).
    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }
}
