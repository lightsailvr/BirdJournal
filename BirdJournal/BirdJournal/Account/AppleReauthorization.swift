import AuthenticationServices
import UIKit

/// Apple's sheet, asked once more when an Apple account is deleted (issue #71). Cognito does the Sign in with Apple
/// exchange itself and keeps Apple's tokens, so the app has none to revoke; a fresh authorization code from the app's
/// own Sign in with Apple lets the server get a token for the bundle's client and revoke it (backend `deletion.py`).
/// Nil when the birder cancels the sheet: the account is deleted all the same.
protocol AppleReauthorizing: AnyObject {
    func authorizationCode() async throws -> String?
}

final class SystemAppleReauthorization: NSObject, AppleReauthorizing, ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<String?, Error>?
    /// Held while the sheet is up.
    private var controller: ASAuthorizationController?

    func authorizationCode() async throws -> String? {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = []
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        self.controller = controller
        defer { self.controller = nil }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        let credential = authorization.credential as? ASAuthorizationAppleIDCredential
        let code = credential?.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
        continuation?.resume(returning: code)
        continuation = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        if let error = error as? ASAuthorizationError, error.code == .canceled {
            continuation?.resume(returning: nil)
        } else {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) { return window }
        if let scene = scenes.first { return ASPresentationAnchor(windowScene: scene) }
        return ASPresentationAnchor()
    }
}
