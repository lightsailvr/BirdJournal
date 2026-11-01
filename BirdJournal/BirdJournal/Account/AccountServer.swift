import Foundation

/// Where the optional account lives (issue #60): the API, the Cognito hosted domain and the app's public client.
/// `infra/scripts/write-app-config.sh` writes them into the bundled `AccountServer.json` after a deploy; none is a
/// secret. Until then the file is empty and Settings → Account says accounts aren't available in this build.
struct AccountServer: Decodable, Equatable {
    var apiURL: URL
    /// The hosted domain without a scheme: `<prefix>.auth.us-west-2.amazoncognito.com`.
    var cognitoDomain: String
    var clientID: String

    /// The app's URL scheme on its own path, registered as the client's callback (infra/cdk.json).
    static let callbackScheme = "birdjournal"
    static let redirectURI = "birdjournal://auth/callback"

    var authorizeURL: URL { URL(string: "https://\(cognitoDomain)/oauth2/authorize")! }
    var tokenURL: URL { URL(string: "https://\(cognitoDomain)/oauth2/token")! }
    var revokeURL: URL { URL(string: "https://\(cognitoDomain)/oauth2/revoke")! }

    /// The bundled settings, or nil before the stack is deployed.
    static func bundled(_ bundle: Bundle = .main) -> AccountServer? {
        guard let url = bundle.url(forResource: "AccountServer", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    static func decode(_ data: Data) -> AccountServer? {
        struct Raw: Decodable { var apiURL: String?; var cognitoDomain: String?; var clientID: String? }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data),
              let api = raw.apiURL, !api.isEmpty, let apiURL = URL(string: api),
              let domain = raw.cognitoDomain, !domain.isEmpty,
              let client = raw.clientID, !client.isEmpty else { return nil }
        return AccountServer(apiURL: apiURL, cognitoDomain: domain, clientID: client)
    }
}
