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
        /// On the art CDN; nil before the stack has one. Without it the row shows the edition's blank.
        var url: URL?

        /// The URL when this is a patch's thumbnail (`packs/<pack id>/patch/…`). A stored find may name a watercolour's
        /// thumbnail or a painting instead, and neither is drawn since #137.
        var patchThumbnailURL: URL? {
            kind == "pack" && key.split(separator: "/").dropFirst(2).first == "patch" ? url : nil
        }
    }

    var sightingID: String
    var speciesID: String
    var scientificName: String
    var commonName: String
    var method: SightingMethod
    var place: String?
    var foundAt: Date
    /// The find sewed the finder's patch: the feed leads it with the patch, and a repeat is a quiet line.
    var newPatch: Bool
    var rarity: RarityLabel?
    var art: Art?
    var owner: Owner
    var circleFirst: Bool
    var isMine: Bool
    /// Every reaction kind with its count and whether the birder gave it (issue #64).
    var reactions: [ReactionCount] = ReactionCount.none

    /// What a card shared by hand to this circle adds (issue #66); nil for an automatic find.
    var card: SharedCard? = nil

    /// The set the sighting is in, by pack id; nil outside every set. Whose patch the feed draws.
    var edition: String? = nil

    /// A card shared by hand: the note, the caption and the original photo the owner chose for this circle.
    struct SharedCard: Equatable, Decodable, Sendable {
        struct Photo: Equatable, Decodable, Sendable {
            var key: String
            var url: URL?
        }

        var note: String?
        var caption: String?
        var photo: Photo?
    }

    var id: String { "\(owner.id)/\(sightingID)" }

    enum CodingKeys: String, CodingKey {
        case sightingID = "sighting_id"
        case speciesID = "species_id"
        case scientificName = "scientific_name"
        case commonName = "common_name"
        case method, place
        case foundAt = "found_at"
        case newPatch = "new_patch"
        case edition, rarity, art, owner
        case circleFirst = "circle_first"
        case isMine = "is_mine"
        case reactions
        case card
    }

    /// The count of one kind.
    func reaction(_ kind: ReactionKind) -> ReactionCount {
        reactions.first { $0.kind == kind } ?? ReactionCount(kind: kind, count: 0, mine: false)
    }

    /// The item with the birder's reaction of this kind given or taken back, as the server will count it.
    func reacting(_ kind: ReactionKind, given: Bool) -> FeedItem {
        var item = self
        item.reactions = ReactionKind.allCases.map { each in
            var count = reaction(each)
            if each == kind, count.mine != given {
                count.count = max(0, count.count + (given ? 1 : -1))
                count.mine = given
            }
            return count
        }
        return item
    }
}

/// Where the phone sends a shared card's original photo (backend `POST /v1/finds/<id>/photo`, issue #66): a presigned
/// POST to the art bucket, the form fields its signed policy covers (it caps the size at 5 MB), and the key the card
/// then names.
struct PhotoUpload: Equatable, Decodable, Sendable {
    var key: String
    var uploadURL: URL
    var fields: [String: String]
    var expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case key
        case uploadURL = "upload_url"
        case fields
        case expiresAt = "expires_at"
    }

    /// The multipart form S3 takes: every policy field, then the JPEG as `file`, last as S3 requires.
    func form(_ jpeg: Data, boundary: String) -> Data {
        var body = Data()
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"photo.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
        body.append(jpeg)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }
}

extension FeedItem {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sightingID = try values.decode(String.self, forKey: .sightingID)
        speciesID = try values.decode(String.self, forKey: .speciesID)
        scientificName = try values.decode(String.self, forKey: .scientificName)
        commonName = try values.decode(String.self, forKey: .commonName)
        method = try values.decode(SightingMethod.self, forKey: .method)
        place = try values.decodeIfPresent(String.self, forKey: .place)
        foundAt = try values.decode(Date.self, forKey: .foundAt)
        newPatch = try LegacyFindWire.newPatch(from: decoder)
        rarity = try values.decodeIfPresent(RarityLabel.self, forKey: .rarity)
        art = try values.decodeIfPresent(Art.self, forKey: .art)
        edition = try values.decodeIfPresent(String.self, forKey: .edition) ?? LegacyFindWire.edition(ofArtKey: art?.key)
        owner = try values.decode(Owner.self, forKey: .owner)
        circleFirst = try values.decode(Bool.self, forKey: .circleFirst)
        isMine = try values.decode(Bool.self, forKey: .isMine)
        // A server from before reactions sends none.
        reactions = ReactionCount.complete(try values.decodeIfPresent([ReactionCount.Sent].self, forKey: .reactions) ?? [])
        // A find not shared by hand to this circle has no card (issue #66).
        card = try values.decodeIfPresent(SharedCard.self, forKey: .card)
    }
}

/// The fixed reactions on a find (issue #64): no comments.
enum ReactionKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case lovely
    case jealous
    case together

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lovely: "Lovely find"
        case .jealous: "Jealous!"
        case .together: "Let's go together"
        }
    }

    var symbol: String {
        switch self {
        case .lovely: "heart"
        case .jealous: "eyes"
        case .together: "binoculars"
        }
    }
}

struct ReactionCount: Equatable, Sendable {
    var kind: ReactionKind
    var count: Int
    /// Whether the signed-in birder gave it.
    var mine: Bool

    static let none = ReactionKind.allCases.map { ReactionCount(kind: $0, count: 0, mine: false) }

    /// As the API sends one: a kind added after this build is left out rather than failing the item.
    struct Sent: Decodable {
        var kind: String
        var count: Int
        var mine: Bool
    }

    /// Every kind this build knows, in order, from what the API sent; a kind it didn't send counts nothing.
    static func complete(_ sent: [Sent]) -> [ReactionCount] {
        ReactionKind.allCases.map { kind in
            sent.first { $0.kind == kind.rawValue }.map { ReactionCount(kind: kind, count: $0.count, mine: $0.mine) }
                ?? ReactionCount(kind: kind, count: 0, mine: false)
        }
    }
}

/// A friend's side of Compare birds (backend `GET /v1/friends/<id>/compare`, issue #64): each species they found in
/// the circles the two share, with their best method (Seen beats Heard).
struct FriendBirds: Equatable, Decodable, Sendable {
    struct Species: Equatable, Decodable, Sendable {
        var speciesID: String
        var scientificName: String
        var commonName: String
        var method: SightingMethod

        enum CodingKeys: String, CodingKey {
            case speciesID = "species_id"
            case scientificName = "scientific_name"
            case commonName = "common_name"
            case method
        }
    }

    var friend: FeedItem.Owner
    var species: [Species]
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

/// A circle's goal (backend `GET /v1/circles/<id>/goals`, issue #65): the automatic monthly goal or a custom one, with
/// its progress, the distinct species among the circle's finds in the period.
struct CircleGoal: Equatable, Identifiable, Decodable, Sendable {
    enum Kind: String, Decodable, Sendable { case monthly, custom }
    enum Status: String, Decodable, Sendable { case upcoming, active, ended }

    var id: String
    var kind: Kind
    var title: String
    var target: Int
    /// The first and last days, in the circle's time zone, both included ("2026-11-01").
    var startDate: String
    var endDate: String
    /// The same period as instants: midnight starting the first day to midnight ending the last.
    var startsAt: Date
    var endsAt: Date
    var progress: Int
    var status: Status
    /// When progress first reached the target; it stays if a delete takes progress back down.
    var completedAt: Date?
    /// Who made a custom goal; nil for the monthly goal.
    var createdBy: FeedItem.Owner?
    /// The goal's creator or the circle's creator may delete a custom goal.
    var canDelete: Bool

    enum CodingKeys: String, CodingKey {
        case id, kind, title, target, progress, status
        case startDate = "start_date"
        case endDate = "end_date"
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case completedAt = "completed_at"
        case createdBy = "created_by"
        case canDelete = "can_delete"
    }

    var isReached: Bool { progress >= target }
}

/// What the new-goal sheet sends: a title, a target, and the first and last days in the circle's time zone.
struct GoalDraft: Equatable, Encodable, Sendable {
    var title: String
    var target: Int
    var startDate: String
    var endDate: String

    enum CodingKeys: String, CodingKey {
        case title, target
        case startDate = "start_date"
        case endDate = "end_date"
    }

    /// A goal's day as the API writes it, "2026-11-01", in the circle's zone.
    static func dayFormatter(_ zone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}

/// What the birder muted (backend `GET /v1/mutes`, issue #63): circles and friends whose finds send no pushes.
struct Mutes: Equatable, Decodable, Sendable {
    var circles: Set<String> = []
    var friends: Set<String> = []
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
    /// Only a custom goal's creator or the circle's creator deletes it, and the monthly goal stays (issue #65).
    case goalNotYours
    /// Twenty reports today already (issue #71).
    case tooManyReports
    /// Nobody reports or blocks themselves.
    case ownAccount
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
    /// Shares a card by hand (issue #66): the find with the extras chosen, in the circles chosen.
    func shareCard(_ card: FindPolicy.Card, sightingID: UUID, accessToken: String) async throws
    /// An upload URL for a shared card's original photo.
    func photoUpload(sightingID: UUID, accessToken: String) async throws -> PhotoUpload
    /// POSTs the photo (faces blurred, metadata stripped) to the URL: no access token, the form is signed.
    func uploadPhoto(_ jpeg: Data, to upload: PhotoUpload) async throws
    /// Pushes (issue #63): the phone's APNs token and environment go to the signed-in account, and leave it at sign-out.
    func registerDevice(token: String, environment: PushEnvironment, accessToken: String) async throws
    func unregisterDevice(token: String, accessToken: String) async throws
    func mutes(accessToken: String) async throws -> Mutes
    func setCircleMuted(_ muted: Bool, circleID: String, accessToken: String) async throws
    func setFriendMuted(_ muted: Bool, friendID: String, accessToken: String) async throws
    /// Goals (issue #65): this month's goal first, then custom goals running, coming and recently ended.
    func goals(circleID: String, accessToken: String) async throws -> [CircleGoal]
    func createGoal(_ draft: GoalDraft, circleID: String, accessToken: String) async throws -> CircleGoal
    func deleteGoal(id: String, circleID: String, accessToken: String) async throws
    /// Gives or takes back a reaction on a friend's find (issue #64); the find's counts as the server has them.
    func setReaction(_ kind: ReactionKind, given: Bool, owner: String, sightingID: String, accessToken: String) async throws -> [ReactionCount]
    /// A friend's species from their finds in the circles the two share, best method each.
    func compare(friendID: String, accessToken: String) async throws -> FriendBirds
    /// Reports a find or a member to the maintainer (issue #71).
    func report(_ report: ReportDraft, accessToken: String) async throws
    /// The accounts the birder blocked, and blocking or unblocking one: their finds, reactions and pushes are hidden.
    func blocks(accessToken: String) async throws -> [BlockedAccount]
    func setBlocked(_ blocked: Bool, accountID: String, accessToken: String) async throws
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
        try await putNewFormElseOld(find, "v1/finds/\(sightingID.uuidString.lowercased())", accessToken: accessToken)
    }

    func deleteFind(sightingID: UUID, accessToken: String) async throws {
        _ = try await data("DELETE", "v1/finds/\(sightingID.uuidString.lowercased())", body: nil, accessToken: accessToken)
    }

    func feed(circleID: String, cursor: String?, accessToken: String) async throws -> FeedPage {
        var query = [URLQueryItem(name: "limit", value: String(Self.feedPageSize))]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await send("GET", "v1/circles/\(circleID)/feed", query: query, accessToken: accessToken, as: FeedPage.self)
    }

    func shareCard(_ card: FindPolicy.Card, sightingID: UUID, accessToken: String) async throws {
        try await putNewFormElseOld(card, "v1/finds/\(sightingID.uuidString.lowercased())/card", accessToken: accessToken)
    }

    func photoUpload(sightingID: UUID, accessToken: String) async throws -> PhotoUpload {
        try await send("POST", "v1/finds/\(sightingID.uuidString.lowercased())/photo", accessToken: accessToken, as: PhotoUpload.self)
    }

    func uploadPhoto(_ jpeg: Data, to upload: PhotoUpload) async throws {
        let boundary = "BirdJournal-\(UUID().uuidString)"
        var request = URLRequest(url: upload.uploadURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = upload.form(jpeg, boundary: boundary)
        let (_, response) = try await transport(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw CircleError.server(status) }
    }

    static let feedPageSize = 20

    func registerDevice(token: String, environment: PushEnvironment, accessToken: String) async throws {
        _ = try await data("PUT", "v1/account/devices/\(token)", body: try JSONEncoder().encode(["environment": environment.rawValue]), accessToken: accessToken)
    }

    func unregisterDevice(token: String, accessToken: String) async throws {
        _ = try await data("DELETE", "v1/account/devices/\(token)", body: nil, accessToken: accessToken)
    }

    func mutes(accessToken: String) async throws -> Mutes {
        try await send("GET", "v1/mutes", accessToken: accessToken, as: Mutes.self)
    }

    func setCircleMuted(_ muted: Bool, circleID: String, accessToken: String) async throws {
        _ = try await data(muted ? "PUT" : "DELETE", "v1/circles/\(circleID)/mute", body: nil, accessToken: accessToken)
    }

    func setFriendMuted(_ muted: Bool, friendID: String, accessToken: String) async throws {
        _ = try await data(muted ? "PUT" : "DELETE", "v1/friends/\(friendID)/mute", body: nil, accessToken: accessToken)
    }

    func goals(circleID: String, accessToken: String) async throws -> [CircleGoal] {
        struct List: Decodable { var goals: [CircleGoal] }
        return try await send("GET", "v1/circles/\(circleID)/goals", accessToken: accessToken, as: List.self).goals
    }

    func createGoal(_ draft: GoalDraft, circleID: String, accessToken: String) async throws -> CircleGoal {
        let data = try await data("POST", "v1/circles/\(circleID)/goals", body: try JSONEncoder().encode(draft), accessToken: accessToken)
        return try Self.decode(CircleGoal.self, from: data)
    }

    func deleteGoal(id: String, circleID: String, accessToken: String) async throws {
        _ = try await data("DELETE", "v1/circles/\(circleID)/goals/\(id)", body: nil, accessToken: accessToken)
    }

    func setReaction(_ kind: ReactionKind, given: Bool, owner: String, sightingID: String, accessToken: String) async throws -> [ReactionCount] {
        struct Counts: Decodable { var reactions: [ReactionCount.Sent] }
        let counts = try await send(given ? "PUT" : "DELETE", "v1/finds/\(owner)/\(sightingID)/reactions/\(kind.rawValue)", accessToken: accessToken, as: Counts.self)
        return ReactionCount.complete(counts.reactions)
    }

    func compare(friendID: String, accessToken: String) async throws -> FriendBirds {
        try await send("GET", "v1/friends/\(friendID)/compare", accessToken: accessToken, as: FriendBirds.self)
    }

    func report(_ report: ReportDraft, accessToken: String) async throws {
        _ = try await data("POST", "v1/reports", body: try JSONEncoder().encode(report), accessToken: accessToken)
    }

    func blocks(accessToken: String) async throws -> [BlockedAccount] {
        struct List: Decodable { var accounts: [BlockedAccount] }
        return try await send("GET", "v1/blocks", accessToken: accessToken, as: List.self).accounts
    }

    func setBlocked(_ blocked: Bool, accountID: String, accessToken: String) async throws {
        _ = try await data(blocked ? "PUT" : "DELETE", "v1/blocks/\(accountID)", body: nil, accessToken: accessToken)
    }

    /// A find or a shared card. Compatibility until the backend deploy (`LegacyFindWire`, #136): the deployed server
    /// refuses `new_patch` before it writes anything, so a refusal is tried once more in the old form. A find it would
    /// refuse anyway (a coordinate in the place) is refused again, and the outbox drops it as before. Once the server
    /// speaks `new_patch` the first try goes through.
    private func putNewFormElseOld(_ body: some Encodable, _ path: String, accessToken: String) async throws {
        do {
            _ = try await data("PUT", path, body: try JSONEncoder().encode(body), accessToken: accessToken)
        } catch CircleError.rejected {
            _ = try await data("PUT", path, body: try LegacyFindWire.oldFormEncoder().encode(body), accessToken: accessToken)
        }
    }

    private func send<T: Decodable>(_ method: String, _ path: String, body: [String: String]? = nil, query: [URLQueryItem] = [], accessToken: String, as type: T.Type) async throws -> T {
        try Self.decode(T.self, from: try await data(method, path, query: query, body: try body.map { try JSONEncoder().encode($0) }, accessToken: accessToken))
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
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
        case (403, "not_allowed"), (403, "automatic_goal"): return .goalNotYours
        case (403, _): return .creatorOnly
        case (404, _): return .notFound
        case (409, _): return .full
        case (410, _): return .inviteExpired
        case (422, "own_account"): return .ownAccount
        case (422, _): return .rejected
        case (429, "too_many_reports"): return .tooManyReports
        default: return .server(status)
        }
    }
}
