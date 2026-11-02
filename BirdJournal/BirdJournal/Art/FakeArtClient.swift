#if DEBUG
import CoreImage
import Foundation

/// The art server in memory, for the tests and the simulator (`-fakeArt paints|pending|fails`, issue #68). A job is
/// created, waits for its photo, and on submit is painted at once (a warm wash over the uploaded photo, so a screenshot
/// shows it came from it), stays queued as if the painting machine were off, or fails.
final class FakeArtClient: ArtClient {
    enum Behaviour: String {
        case paints
        case pending
        case fails
    }

    var behaviour: Behaviour
    /// Every job by id, as the server holds it.
    private(set) var jobs: [UUID: RemoteArtJob] = [:]
    private(set) var requests: [ArtJobRequest] = []
    private(set) var uploads: [UUID: Data] = [:]
    private(set) var received: [UUID] = []
    private var paintings: [URL: Data] = [:]
    /// Calls fail with this while set (no connection, the API down).
    var failing: Error?

    init(behaviour: Behaviour = .paints) {
        self.behaviour = behaviour
    }

    func createJob(_ request: ArtJobRequest, accessToken: String) async throws -> RemoteArtJob {
        if let failing { throw failing }
        requests.append(request)
        if var existing = jobs[request.id] {
            existing.upload = existing.state == .awaitingUpload ? Self.upload(for: request.id) : nil
            return existing
        }
        let job = RemoteArtJob(id: request.id, sightingID: request.sightingID, state: .awaitingUpload, upload: Self.upload(for: request.id))
        jobs[request.id] = job
        return job
    }

    func upload(_ jpeg: Data, to upload: RemoteArtJob.Upload) async throws {
        if let failing { throw failing }
        guard let id = UUID(uuidString: upload.url.deletingPathExtension().lastPathComponent) else { throw ArtClientError.server(403) }
        uploads[id] = jpeg
    }

    func submit(jobID: UUID, accessToken: String) async throws -> RemoteArtJob {
        if let failing { throw failing }
        guard var job = jobs[jobID] else { throw ArtClientError.notFound }
        guard job.state == .awaitingUpload else { return job }
        guard let photo = uploads[jobID] else { throw ArtClientError.uploadMissing }
        job.upload = nil
        switch behaviour {
        case .pending:
            job.state = .queued
        case .fails:
            job.state = .failed
            job.failure = "painting_failed"
        case .paints:
            let url = URL(string: "https://art.fake.example/art/\(jobID.uuidString).jpg")!
            paintings[url] = Self.paint(photo) ?? photo
            job.state = .ready
            job.artURL = url
        }
        jobs[jobID] = job
        return job
    }

    func job(id: UUID, accessToken: String) async throws -> RemoteArtJob {
        if let failing { throw failing }
        guard var job = jobs[id] else { throw ArtClientError.notFound }
        job.upload = nil
        return job
    }

    func openJobs(accessToken: String) async throws -> [RemoteArtJob] {
        if let failing { throw failing }
        return jobs.values.filter { !received.contains($0.id) }.map { var job = $0; job.upload = nil; return job }
    }

    func received(jobID: UUID, accessToken: String) async throws {
        if let failing { throw failing }
        guard let job = jobs[jobID], job.state == .ready || job.state == .failed else { throw ArtClientError.server(409) }
        if !received.contains(jobID) { received.append(jobID) }
        if let url = job.artURL { paintings[url] = nil }
        jobs[jobID]?.artURL = nil
    }

    func download(_ url: URL) async throws -> Data {
        if let failing { throw failing }
        guard let data = paintings[url] else { throw ArtClientError.server(404) }
        return data
    }

    /// The painting machine finishing a queued job later (the box coming back on).
    func finishQueued(_ id: UUID, failing reason: String? = nil) {
        guard var job = jobs[id], job.state == .queued || job.state == .painting else { return }
        if let reason {
            job.state = .failed
            job.failure = reason
        } else {
            let url = URL(string: "https://art.fake.example/art/\(id.uuidString).jpg")!
            paintings[url] = uploads[id].flatMap(Self.paint) ?? uploads[id]
            job.state = .ready
            job.artURL = url
        }
        jobs[id] = job
    }

    private static func upload(for id: UUID) -> RemoteArtJob.Upload {
        RemoteArtJob.Upload(url: URL(string: "https://uploads.fake.example/uploads/\(id.uuidString).jpg")!, headers: ["Content-Type": "image/jpeg"])
    }

    /// A warm, soft wash over the photo: plainly not the photo, plainly from it.
    static func paint(_ photo: Data) -> Data? {
        guard let image = CIImage(data: photo) else { return nil }
        let washed = image
            .applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 0.6])
            .applyingFilter("CIBloom", parameters: [kCIInputRadiusKey: 8, kCIInputIntensityKey: 0.6])
            .cropped(to: image.extent)
        return try? ArtPhoto.encode(washed)
    }
}
#endif
