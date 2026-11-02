import Foundation

/// One art job as the server has it (backend `art_api.py`, issue #68).
struct RemoteArtJob: Equatable, Decodable, Sendable {
    enum State: String, Decodable, Sendable {
        case awaitingUpload = "awaiting_upload"
        case queued
        case painting
        case ready
        case failed
    }

    struct Upload: Equatable, Decodable, Sendable {
        var url: URL
        var headers: [String: String]
    }

    var id: UUID
    var sightingID: UUID
    var state: State
    /// The painting on the art CDN, once ready and until the phone says it has it.
    var artURL: URL?
    /// "expired", "filtered", "no_reference", "no_bird" (photo art), "painting_failed" or "bad_input".
    var failure: String?
    /// Present while the job waits for its photo.
    var upload: Upload?

    enum CodingKeys: String, CodingKey {
        case id, state, failure, upload
        case sightingID = "sighting_id"
        case artURL = "art_url"
    }
}

/// What the phone asks to be painted: one sighting's scene art, or photo art from the birder's photo (issue #69).
struct ArtJobRequest: Equatable, Encodable, Sendable {
    var id: UUID
    var sightingID: UUID
    /// "scene" or "photo".
    var kind = "scene"
    var scientificName: String
    /// The pack id of the card's set, whose edition lights the painting; nil outside every set.
    var edition: String?
    var legendary: Bool
    var rarity: String?
    /// Try again or Retry art, rather than the add; photo art always is.
    var requested: Bool

    enum CodingKeys: String, CodingKey {
        case id, kind, edition, legendary, rarity, requested
        case sightingID = "sighting_id"
        case scientificName = "scientific_name"
    }
}

/// Today's paintings on request (issue #69): at the public launch 5 a day per account, shown as "N left today"; no
/// limit in the friends phase.
struct ArtAllowance: Equatable, Decodable, Sendable {
    /// Nil when there is no limit.
    var daily: Int?
    var left: Int?
    var resetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case daily, left
        case resetsAt = "resets_at"
    }

    static let unlimited = ArtAllowance(daily: nil, left: nil, resetsAt: nil)

    init(daily: Int?, left: Int?, resetsAt: Date?) {
        self.daily = daily
        self.left = left
        self.resetsAt = resetsAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        daily = try container.decodeIfPresent(Int.self, forKey: .daily)
        left = try container.decodeIfPresent(Int.self, forKey: .left)
        resetsAt = (try container.decodeIfPresent(String.self, forKey: .resetsAt)).flatMap { try? Date($0, strategy: .iso8601) }
    }

    /// Whether another painting on request may be asked for today.
    var hasPaintingsLeft: Bool { left.map { $0 > 0 } ?? true }
}

enum ArtClientError: Error, Equatable {
    /// The access token was refused: `AccountSession` renews it and tries once more.
    case unauthorized
    /// No such job (the server never got it, or it was received and cleaned up).
    case notFound
    /// The auto-paint rule doesn't paint this add.
    case notEligible
    /// Today's paintings on request are used up.
    case allowanceSpent
    /// Submitted before the photo arrived.
    case uploadMissing
    case server(Int)
}

/// The art routes of the BirdJournal API, and the two plain HTTP calls around them (the presigned upload and the art
/// CDN). `HTTPArtClient` talks to the stack; `FakeArtClient` paints in memory for the tests and the simulator.
protocol ArtClient: AnyObject {
    func createJob(_ request: ArtJobRequest, accessToken: String) async throws -> RemoteArtJob
    func upload(_ jpeg: Data, to upload: RemoteArtJob.Upload) async throws
    func submit(jobID: UUID, accessToken: String) async throws -> RemoteArtJob
    func job(id: UUID, accessToken: String) async throws -> RemoteArtJob
    func openJobs(accessToken: String) async throws -> [RemoteArtJob]
    func received(jobID: UUID, accessToken: String) async throws
    func download(_ url: URL) async throws -> Data
    func allowance(accessToken: String) async throws -> ArtAllowance
}

final class HTTPArtClient: ArtClient {
    private let baseURL: URL
    private let transport: HTTPTransport

    init(baseURL: URL, transport: @escaping HTTPTransport = { try await URLSession.shared.data(for: $0) }) {
        self.baseURL = baseURL
        self.transport = transport
    }

    func createJob(_ request: ArtJobRequest, accessToken: String) async throws -> RemoteArtJob {
        try decode(try await send("POST", "v1/art/jobs", body: try JSONEncoder().encode(request), accessToken: accessToken))
    }

    func upload(_ jpeg: Data, to upload: RemoteArtJob.Upload) async throws {
        var request = URLRequest(url: upload.url)
        request.httpMethod = "PUT"
        for (name, value) in upload.headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = jpeg
        let (_, response) = try await transport(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw ArtClientError.server(status) }
    }

    func submit(jobID: UUID, accessToken: String) async throws -> RemoteArtJob {
        try decode(try await send("POST", "v1/art/jobs/\(jobID.uuidString.lowercased())/submit", accessToken: accessToken))
    }

    func job(id: UUID, accessToken: String) async throws -> RemoteArtJob {
        try decode(try await send("GET", "v1/art/jobs/\(id.uuidString.lowercased())", accessToken: accessToken))
    }

    func openJobs(accessToken: String) async throws -> [RemoteArtJob] {
        struct List: Decodable { var jobs: [RemoteArtJob] }
        return try decode(try await send("GET", "v1/art/jobs", accessToken: accessToken), as: List.self).jobs
    }

    func received(jobID: UUID, accessToken: String) async throws {
        _ = try await send("POST", "v1/art/jobs/\(jobID.uuidString.lowercased())/received", accessToken: accessToken)
    }

    func download(_ url: URL) async throws -> Data {
        let (data, response) = try await transport(URLRequest(url: url))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw ArtClientError.server(status) }
        return data
    }

    func allowance(accessToken: String) async throws -> ArtAllowance {
        try decode(try await send("GET", "v1/art/allowance", accessToken: accessToken))
    }

    private func decode<T: Decodable>(_ data: Data, as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: data)
    }

    private func send(_ method: String, _ path: String, body: Data? = nil, accessToken: String) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
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

    static func error(status: Int, data: Data) -> ArtClientError {
        struct Detail: Decodable { var detail: String? }
        let detail = (try? JSONDecoder().decode(Detail.self, from: data))?.detail
        switch (status, detail) {
        case (401, _): return .unauthorized
        case (404, _): return .notFound
        case (409, "not_eligible"): return .notEligible
        case (409, "allowance_spent"): return .allowanceSpent
        case (409, "upload_missing"): return .uploadMissing
        default: return .server(status)
        }
    }
}
