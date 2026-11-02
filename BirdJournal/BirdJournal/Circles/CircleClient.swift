import Foundation

/// One of the birder's circles as the list shows it (backend `GET /v1/circles`, issue #61). Named `CircleSummary`, not
/// `Circle`, beside SwiftUI's shape.
struct CircleSummary: Equatable, Identifiable, Decodable, Sendable {
    var id: String
    var name: String
    var createdBy: String
    var createdAt: Date
    var timeZone: String
    var memberCount: Int
    /// Whether the signed-in birder created it, so may remove members.
    var isCreator: Bool

    enum CodingKeys: String, CodingKey {
        case id, name
        case createdBy = "created_by"
        case createdAt = "created_at"
        case timeZone = "time_zone"
        case memberCount = "member_count"
        case isCreator = "is_creator"
    }
}

struct CircleMember: Equatable, Identifiable, Decodable, Sendable {
    var id: String
    var displayName: String?
    var joinedAt: Date
    var isCreator: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case joinedAt = "joined_at"
        case isCreator = "is_creator"
    }

    /// The name to show; an account that never set one is still a friend.
    var name: String { displayName ?? "A birder" }

    /// Avatars are initials only (spec v2, "Accounts and the app client").
    var initials: String {
        let words = name.split(whereSeparator: \.isWhitespace).prefix(2)
        return words.compactMap(\.first).map(String.init).joined().uppercased()
    }
}

/// A circle's page: the circle and its current members, oldest first.
struct CircleDetail: Equatable, Decodable, Sendable {
    var circle: CircleSummary
    var members: [CircleMember]

    init(circle: CircleSummary, members: [CircleMember]) {
        self.circle = circle
        self.members = members
    }

    init(from decoder: Decoder) throws {
        circle = try CircleSummary(from: decoder)
        members = try decoder.container(keyedBy: CodingKeys.self).decode([CircleMember].self, forKey: .members)
    }

    enum CodingKeys: String, CodingKey { case members }
}

/// A link any member makes; the QR code encodes the same URL. It expires after seven days.
struct CircleInvite: Equatable, Decodable, Sendable {
    var token: String
    var url: URL
    var expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case token, url
        case expiresAt = "expires_at"
    }
}

/// What the join screen shows before joining.
struct InvitePreview: Equatable, Decodable, Sendable {
    var circle: CircleSummary
    var invitedBy: String?
    var expiresAt: Date
    var alreadyMember: Bool

    enum CodingKeys: String, CodingKey {
        case circle
        case invitedBy = "invited_by"
        case expiresAt = "expires_at"
        case alreadyMember = "already_member"
    }
}

enum CircleError: Error, Equatable {
    /// The access token was refused: renew it and try once more (the account's 401, so `AccountSession` retries).
    case unauthorized
    /// Not a member, or no such circle, member or invite.
    case notFound
    /// Only the creator removes members.
    case creatorOnly
    /// The circle has 20 members already.
    case full
    case inviteExpired
    /// The creator removed this account after the invite was made.
    case inviteRevoked
    /// The server turned the name down.
    case rejected
    case server(Int)
}

/// The circle routes of the BirdJournal API. `HTTPCircleClient` talks to the stack; `FakeCircleClient` keeps circles
/// in memory for the tests and the simulator.
protocol CircleClient: AnyObject {
    func circles(accessToken: String) async throws -> [CircleSummary]
    func createCircle(named name: String, timeZone: String, accessToken: String) async throws -> CircleDetail
    func circle(id: String, accessToken: String) async throws -> CircleDetail
    func createInvite(circleID: String, accessToken: String) async throws -> CircleInvite
    func invitePreview(token: String, accessToken: String) async throws -> InvitePreview
    func acceptInvite(token: String, accessToken: String) async throws -> CircleDetail
    func leave(circleID: String, accessToken: String) async throws
    func removeMember(_ memberID: String, circleID: String, accessToken: String) async throws
}

final class HTTPCircleClient: CircleClient {
    private let baseURL: URL
    private let transport: HTTPTransport

    init(baseURL: URL, transport: @escaping HTTPTransport = { try await URLSession.shared.data(for: $0) }) {
        self.baseURL = baseURL
        self.transport = transport
    }

    func circles(accessToken: String) async throws -> [CircleSummary] {
        struct List: Decodable { var circles: [CircleSummary] }
        return try await send("GET", "v1/circles", accessToken: accessToken, as: List.self).circles
    }

    func createCircle(named name: String, timeZone: String, accessToken: String) async throws -> CircleDetail {
        try await send("POST", "v1/circles", body: ["name": name, "time_zone": timeZone], accessToken: accessToken, as: CircleDetail.self)
    }

    func circle(id: String, accessToken: String) async throws -> CircleDetail {
        try await send("GET", "v1/circles/\(id)", accessToken: accessToken, as: CircleDetail.self)
    }

    func createInvite(circleID: String, accessToken: String) async throws -> CircleInvite {
        try await send("POST", "v1/circles/\(circleID)/invites", accessToken: accessToken, as: CircleInvite.self)
    }

    func invitePreview(token: String, accessToken: String) async throws -> InvitePreview {
        try await send("GET", "v1/invites/\(token)", accessToken: accessToken, as: InvitePreview.self)
    }

    func acceptInvite(token: String, accessToken: String) async throws -> CircleDetail {
        try await send("POST", "v1/invites/\(token)/accept", accessToken: accessToken, as: CircleDetail.self)
    }

    func leave(circleID: String, accessToken: String) async throws {
        _ = try await data("DELETE", "v1/circles/\(circleID)/members/me", body: nil, accessToken: accessToken)
    }

    func removeMember(_ memberID: String, circleID: String, accessToken: String) async throws {
        _ = try await data("DELETE", "v1/circles/\(circleID)/members/\(memberID)", body: nil, accessToken: accessToken)
    }

    private func send<T: Decodable>(_ method: String, _ path: String, body: [String: String]? = nil, accessToken: String, as type: T.Type) async throws -> T {
        let data = try await data(method, path, body: body, accessToken: accessToken)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    private func data(_ method: String, _ path: String, body: [String: String]?, accessToken: String) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await transport(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(status) { return data }
        throw Self.error(status: status, data: data)
    }

    /// The API's refusals: a status and, where one status means two things, the `detail` word.
    static func error(status: Int, data: Data) -> CircleError {
        struct Detail: Decodable { var detail: String? }
        let detail = (try? JSONDecoder().decode(Detail.self, from: data))?.detail
        switch (status, detail) {
        case (401, _): return .unauthorized
        case (403, "invite_revoked"): return .inviteRevoked
        case (403, _): return .creatorOnly
        case (404, _): return .notFound
        case (409, _): return .full
        case (410, _): return .inviteExpired
        case (422, _): return .rejected
        default: return .server(status)
        }
    }
}
