import Album
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

/// One find in a circle's feed (backend `GET /v1/circles/<id>/feed`, issue #62): what the owner's find policy sent,
/// with who found it and whether it is the circle's first of the species.
struct FeedItem: Equatable, Identifiable, Decodable, Sendable {
    struct Owner: Equatable, Decodable, Sendable {
        var id: String
        var displayName: String?

        enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
        }

        var name: String { displayName ?? "A birder" }
    }

    struct Art: Equatable, Decodable, Sendable {
        var kind: String
        var key: String
        /// On the art CDN; nil before the stack has one. Without it the row shows the reference photo or a tile.
        var url: URL?
    }

    var sightingID: String
    var speciesID: String
    var scientificName: String
    var commonName: String
    var method: SightingMethod
    var place: String?
    var foundAt: Date
    var legendary: Bool
    var rarity: RarityLabel?
    var art: Art?
    var owner: Owner
    var circleFirst: Bool
    var isMine: Bool

    var id: String { "\(owner.id)/\(sightingID)" }

    enum CodingKeys: String, CodingKey {
        case sightingID = "sighting_id"
        case speciesID = "species_id"
        case scientificName = "scientific_name"
        case commonName = "common_name"
        case method, place
        case foundAt = "found_at"
        case legendary, rarity, art, owner
        case circleFirst = "circle_first"
        case isMine = "is_mine"
    }
}

/// A page of the feed, newest first; `nextCursor` asks for the next.
struct FeedPage: Equatable, Decodable, Sendable {
    var items: [FeedItem]
    var nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case items
        case nextCursor = "next_cursor"
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
    /// Writes the find of a sighting (issue #62): the first put fans it out to the birder's circles, a repeated one
    /// updates it.
    func putFind(_ find: FindPolicy.Find, sightingID: UUID, accessToken: String) async throws
    /// Removes the find with its feed items and reactions; one that isn't there is no error.
    func deleteFind(sightingID: UUID, accessToken: String) async throws
    func feed(circleID: String, cursor: String?, accessToken: String) async throws -> FeedPage
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

    func putFind(_ find: FindPolicy.Find, sightingID: UUID, accessToken: String) async throws {
        _ = try await data("PUT", "v1/finds/\(sightingID.uuidString.lowercased())", body: try JSONEncoder().encode(find), accessToken: accessToken)
    }

    func deleteFind(sightingID: UUID, accessToken: String) async throws {
        _ = try await data("DELETE", "v1/finds/\(sightingID.uuidString.lowercased())", body: nil, accessToken: accessToken)
    }

    func feed(circleID: String, cursor: String?, accessToken: String) async throws -> FeedPage {
        var query = [URLQueryItem(name: "limit", value: String(Self.feedPageSize))]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await send("GET", "v1/circles/\(circleID)/feed", query: query, accessToken: accessToken, as: FeedPage.self)
    }

    static let feedPageSize = 20

    private func send<T: Decodable>(_ method: String, _ path: String, body: [String: String]? = nil, query: [URLQueryItem] = [], accessToken: String, as type: T.Type) async throws -> T {
        let data = try await data(method, path, query: query, body: try body.map { try JSONEncoder().encode($0) }, accessToken: accessToken)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    private func data(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data?, accessToken: String) async throws -> Data {
        var url = baseURL.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
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
