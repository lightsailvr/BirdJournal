import Foundation

/// The signed-in birder's account as the server holds it (backend `GET /v1/account`).
struct Account: Equatable, Decodable {
    var id: String
    var displayName: String?
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case createdAt = "created_at"
    }
}

enum AccountAPIError: Error, Equatable {
    /// The access token was refused: renew it and try once more.
    case unauthorized
    /// The server turned the change down (a blank or too-long name).
    case rejected
    case server(Int)
}

/// The account routes of the BirdJournal API.
protocol AccountAPI: AnyObject {
    func account(accessToken: String) async throws -> Account
    func setDisplayName(_ name: String, accessToken: String) async throws -> Account
}

final class HTTPAccountAPI: AccountAPI {
    private let baseURL: URL
    private let transport: HTTPTransport

    init(baseURL: URL, transport: @escaping HTTPTransport = { try await URLSession.shared.data(for: $0) }) {
        self.baseURL = baseURL
        self.transport = transport
    }

    func account(accessToken: String) async throws -> Account {
        try await send(request("GET", accessToken: accessToken))
    }

    func setDisplayName(_ name: String, accessToken: String) async throws -> Account {
        var request = request("PATCH", accessToken: accessToken)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["display_name": name])
        return try await send(request)
    }

    private func request(_ method: String, accessToken: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: "v1/account"))
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func send(_ request: URLRequest) async throws -> Account {
        let (data, response) = try await transport(request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200:
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Account.self, from: data)
        case 401: throw AccountAPIError.unauthorized
        case 422: throw AccountAPIError.rejected
        case let status: throw AccountAPIError.server(status)
        }
    }
}
