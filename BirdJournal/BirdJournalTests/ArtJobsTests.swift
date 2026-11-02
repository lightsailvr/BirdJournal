import Album
import Foundation
import SwiftData
import Testing
@testable import BirdJournal

// Issue #68: scene art from the phone. After an add with a glasses photo by a signed-in birder the photo goes up
// prepared and a job is created; the result lands on the same sighting; pending survives the painting machine being
// off and the app being killed; Try again and Retry art are new jobs and never a new sighting.
@MainActor
@Suite("Art jobs")
struct ArtJobsTests {
    let container: ModelContainer
    let frames: FrameStore
    let client: FakeArtClient
    let art: ArtJobs
    let prepared = Data("prepared photo".utf8)

    init() throws {
        container = try AlbumSchema.makeContainer(inMemory: true)
        frames = FrameStore(directory: URL.temporaryDirectory.appending(path: "ArtJobsTests-\(UUID().uuidString)", directoryHint: .isDirectory))
        client = FakeArtClient(behaviour: .paints)
        art = ArtJobs(account: FakeAccount.session(signedIn: true), client: client, frames: frames, container: container)
        art.undoGrace = .zero
        let prepared = prepared
        // The real preparation (faces, metadata) is ArtPhotoTests'; here the upload is told apart from the original.
        art.preparePhoto = { _ in prepared }
        art.cardFacts = { _ in ArtJobs.CardFacts(legendary: true, edition: "us-ca-la") }
    }

    func sighting(frame: Bool = true) throws -> Sighting {
        let path = frame ? try frames.write(jpeg: Data("original glasses photo".utf8)) : nil
        let sighting = Sighting(speciesID: "Haemorhous mexicanus_House Finch", confirmedAt: .now, soundConfidence: 0.8, frameImagePath: path, source: .glasses)
        sighting.rarity = RaritySnapshot(occurrence: 0.4, label: .common, calibrationVersion: 1, week: 40)
        container.mainContext.insert(sighting)
        try container.mainContext.save()
        return sighting
    }

    func sightingCount() throws -> Int {
        try container.mainContext.fetchCount(FetchDescriptor<Sighting>())
    }

    func until(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test("An add with a glasses photo sends the prepared photo, and the painting lands on that card")
    func addLandsArt() async throws {
        let sighting = try sighting()
        art.requestAfterAdd(sighting)
        await until { sighting.art.scene != nil }

        let request = try #require(client.requests.first)
        #expect(request.sightingID == sighting.identifier)
        #expect(request.scientificName == "Haemorhous mexicanus")
        #expect(request.edition == "us-ca-la")
        #expect(request.legendary)
        #expect(request.rarity == "common")
        #expect(!request.requested)
        #expect(client.uploads[request.id] == prepared)
        #expect(sighting.art.sceneStatus == .ready(showsPackArt: false))
        let path = try #require(sighting.art.scene?.path)
        #expect(FileManager.default.fileExists(atPath: frames.url(for: path).path(percentEncoded: false)))
        #expect(client.received == [request.id])
        #expect(try sightingCount() == 1)
    }

    @Test("Nothing is sent without an account, without a photo, or for an add undone in its window")
    func nothingSent() async throws {
        let signedOut = ArtJobs(account: FakeAccount.session(signedIn: false), client: client, frames: frames, container: container)
        signedOut.undoGrace = .zero
        signedOut.requestAfterAdd(try sighting())
        art.requestAfterAdd(try sighting(frame: false))
        art.undoGrace = .milliseconds(100)
        let undone = try sighting()
        art.requestAfterAdd(undone)
        container.mainContext.delete(undone)
        try container.mainContext.save()
        try await Task.sleep(for: .milliseconds(300))
        #expect(client.requests.isEmpty)
        #expect(!ArtJobs(account: FakeAccount.session(signedIn: true), client: nil, frames: frames, container: container).isAvailable)
    }

    @Test("With the painting machine off the card stays pending, and the painting lands when it comes back")
    func pendingSurvives() async throws {
        client.behaviour = .pending
        let sighting = try sighting()
        await art.paintAgain(sighting)
        let job = try #require(sighting.art.pendingSceneJob)
        #expect(sighting.art.sceneStatus == .pending)
        #expect(CardText.sceneArtLine(sighting.art.sceneStatus) == "Your encounter is saved. Artwork is on its way.")

        // Days pass; a relaunch polls and still finds it waiting.
        await art.refresh()
        #expect(sighting.art.sceneStatus == .pending)

        client.finishQueued(job.id)
        await art.refresh()
        #expect(sighting.art.sceneStatus == .ready(showsPackArt: false))
        #expect(try sightingCount() == 1)
    }

    @Test("A job written but never sent (no connection, a killed app) is sent by the next refresh, once")
    func unsentJobIsResent() async throws {
        let sighting = try sighting()
        client.failing = URLError(.notConnectedToInternet)
        await art.paintAgain(sighting)
        let job = try #require(sighting.art.pendingSceneJob)
        #expect(client.jobs.isEmpty)

        client.failing = nil
        await art.refresh()
        #expect(sighting.art.sceneStatus == .ready(showsPackArt: false))
        #expect(Set(client.requests.map(\.id)) == [job.id])
        #expect(try sightingCount() == 1)
    }

    @Test("A job created but whose upload was lost is uploaded and submitted on the next refresh")
    func interruptedUploadResumes() async throws {
        client.behaviour = .pending
        let sighting = try sighting()
        let id = UUID()
        sighting.art.startSceneJob(id: id)
        _ = try await client.createJob(ArtJobRequest(id: id, sightingID: sighting.identifier, scientificName: "Haemorhous mexicanus", legendary: false, requested: false), accessToken: "t")
        await art.refresh(sighting)
        #expect(client.uploads[id] == prepared)
        #expect(client.jobs[id]?.state == .queued)
    }

    @Test("Try again is a new job on the same card; the last painting stays until the new one is ready")
    func tryAgain() async throws {
        let sighting = try sighting()
        await art.paintAgain(sighting)
        let firstPath = try #require(sighting.art.scene?.path)

        client.behaviour = .pending
        await art.paintAgain(sighting)
        let second = try #require(sighting.art.pendingSceneJob)
        #expect(sighting.art.scene?.path == firstPath)
        #expect(second.attempts == 2)
        #expect(client.requests.last?.requested == true)

        client.finishQueued(second.id)
        await art.refresh()
        let secondPath = try #require(sighting.art.scene?.path)
        #expect(secondPath != firstPath)
        // The replaced painting is gone from the phone.
        #expect(!FileManager.default.fileExists(atPath: frames.url(for: firstPath).path(percentEncoded: false)))
        #expect(Set(client.requests.map(\.id)).count == 2)
        #expect(try sightingCount() == 1)
    }

    @Test("A failure offers Retry art; the retry never duplicates the sighting")
    func retryArt() async throws {
        client.behaviour = .fails
        let sighting = try sighting()
        await art.paintAgain(sighting)
        #expect(sighting.art.sceneStatus == .failed)
        #expect(CardText.sceneArtLine(.failed) != nil)

        client.behaviour = .paints
        await art.paintAgain(sighting)
        #expect(sighting.art.sceneStatus == .ready(showsPackArt: false))
        #expect(sighting.art.job == nil)
        #expect(client.requests.count == 2 && client.requests.last?.requested == true)
        #expect(try sightingCount() == 1)
        #expect(client.requests.allSatisfy { $0.sightingID == sighting.identifier })
    }

    @Test("A job that expired on the server (7 days in the queue) fails on the card")
    func expired() async throws {
        client.behaviour = .pending
        let sighting = try sighting()
        await art.paintAgain(sighting)
        let job = try #require(sighting.art.pendingSceneJob)
        client.finishQueued(job.id, failing: "expired")
        await art.refresh()
        #expect(sighting.art.sceneStatus == .failed)
        #expect(client.received == [job.id])
    }

    @Test("Keep current art dismisses the failure; Use pack art and back")
    func choices() async throws {
        client.behaviour = .fails
        let sighting = try sighting()
        await art.paintAgain(sighting)
        art.keepCurrentArt(sighting)
        #expect(sighting.art.sceneStatus == .none)

        client.behaviour = .paints
        await art.paintAgain(sighting)
        art.setShowsPackArt(true, on: sighting)
        #expect(sighting.art.sceneStatus == .ready(showsPackArt: true))
        art.setShowsPackArt(false, on: sighting)
        #expect(sighting.art.sceneStatus == .ready(showsPackArt: false))
    }

    @Test("A server that doesn't paint this add (the launch rule) leaves the card with its pack art")
    func notEligible() async throws {
        let refusing = RefusingArtClient()
        let art = ArtJobs(account: FakeAccount.session(signedIn: true), client: refusing, frames: frames, container: container)
        let sighting = try sighting()
        await art.paintAgain(sighting)
        #expect(sighting.art.job == nil)
        #expect(sighting.art.sceneStatus == .none)
    }

    @Test("Finished jobs no card waits on any more are acknowledged, so their art leaves the server")
    func orphansAreAcknowledged() async throws {
        client.behaviour = .pending
        let sighting = try sighting()
        await art.paintAgain(sighting)
        let job = try #require(sighting.art.pendingSceneJob)
        container.mainContext.delete(sighting)
        try container.mainContext.save()
        client.finishQueued(job.id)
        await art.refresh()
        #expect(client.received == [job.id])
    }
}

/// A server whose auto-paint rule refuses every add.
private final class RefusingArtClient: ArtClient {
    func createJob(_ request: ArtJobRequest, accessToken: String) async throws -> RemoteArtJob { throw ArtClientError.notEligible }
    func upload(_ jpeg: Data, to upload: RemoteArtJob.Upload) async throws {}
    func submit(jobID: UUID, accessToken: String) async throws -> RemoteArtJob { throw ArtClientError.notFound }
    func job(id: UUID, accessToken: String) async throws -> RemoteArtJob { throw ArtClientError.notFound }
    func openJobs(accessToken: String) async throws -> [RemoteArtJob] { [] }
    func received(jobID: UUID, accessToken: String) async throws {}
    func download(_ url: URL) async throws -> Data { Data() }
}

@Suite("Art client")
struct ArtClientTests {
    final class Recorder: @unchecked Sendable {
        var requests: [URLRequest] = []
        var replies: [(Int, String)] = []
    }

    static func client(_ recorder: Recorder) -> HTTPArtClient {
        HTTPArtClient(baseURL: URL(string: "https://api.example")!) { request in
            recorder.requests.append(request)
            let (status, body) = recorder.replies.isEmpty ? (200, "{}") : recorder.replies.removeFirst()
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    static let jobJSON = """
        {"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "sighting_id": "00000000-0000-0000-0000-000000000007", "kind": "scene",
         "state": "awaiting_upload", "legendary": true, "created_at": "2026-11-01T09:30:00Z", "queued_at": null,
         "finished_at": null, "expires_at": "2026-11-08T09:30:00Z", "art_url": null, "failure": null, "provenance": null,
         "received": false, "upload": {"url": "https://uploads.example/uploads/a/j.jpg?sig=1", "method": "PUT",
         "headers": {"Content-Type": "image/jpeg"}, "expires_at": "2026-11-01T10:30:00Z"}}
        """

    @Test("Create posts the job with the account's token and decodes the upload")
    func create() async throws {
        let recorder = Recorder()
        recorder.replies = [(201, Self.jobJSON)]
        let request = ArtJobRequest(
            id: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!, sightingID: UUID(uuidString: "00000000-0000-0000-0000-000000000007")!,
            scientificName: "Haemorhous mexicanus", edition: "us-ca-la", legendary: true, rarity: "rare", requested: false
        )
        let job = try await Self.client(recorder).createJob(request, accessToken: "token")
        let sent = try #require(recorder.requests.first)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.absoluteString == "https://api.example/v1/art/jobs")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        let body = try #require(try JSONSerialization.jsonObject(with: sent.httpBody ?? Data()) as? [String: Any])
        #expect(body["kind"] as? String == "scene")
        #expect(body["sighting_id"] as? String == "00000000-0000-0000-0000-000000000007")
        #expect(body["scientific_name"] as? String == "Haemorhous mexicanus")
        #expect(body["edition"] as? String == "us-ca-la")
        #expect(body["legendary"] as? Bool == true)
        #expect(body["rarity"] as? String == "rare")
        #expect(body["requested"] as? Bool == false)
        #expect(job.state == .awaitingUpload)
        #expect(job.upload?.url.absoluteString == "https://uploads.example/uploads/a/j.jpg?sig=1")
        #expect(job.upload?.headers == ["Content-Type": "image/jpeg"])
    }

    @Test("The upload is a PUT of the JPEG with the signed headers and no token")
    func upload() async throws {
        let recorder = Recorder()
        let upload = RemoteArtJob.Upload(url: URL(string: "https://uploads.example/u.jpg?sig=1")!, headers: ["Content-Type": "image/jpeg"])
        try await Self.client(recorder).upload(Data("jpeg".utf8), to: upload)
        let sent = try #require(recorder.requests.first)
        #expect(sent.httpMethod == "PUT")
        #expect(sent.url == upload.url)
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "image/jpeg")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(sent.httpBody == Data("jpeg".utf8))
    }

    @Test("Job routes use the lower-case job id; refusals map to their errors")
    func routesAndRefusals() async throws {
        let recorder = Recorder()
        let id = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
        recorder.replies = [(200, "{}")]
        try await Self.client(recorder).received(jobID: id, accessToken: "t")
        #expect(recorder.requests.last?.url?.absoluteString == "https://api.example/v1/art/jobs/6f9619ff-8b86-d011-b42d-00c04fc964ff/received")
        #expect(HTTPArtClient.error(status: 401, data: Data()) == .unauthorized)
        #expect(HTTPArtClient.error(status: 404, data: Data()) == .notFound)
        #expect(HTTPArtClient.error(status: 409, data: Data(#"{"detail": "not_eligible"}"#.utf8)) == .notEligible)
        #expect(HTTPArtClient.error(status: 409, data: Data(#"{"detail": "upload_missing"}"#.utf8)) == .uploadMissing)
        #expect(HTTPArtClient.error(status: 503, data: Data()) == .server(503))
    }

    @Test("The open jobs list decodes ready art's URL and a failure's reason")
    func openJobs() async throws {
        let recorder = Recorder()
        recorder.replies = [(200, """
            {"jobs": [{"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "sighting_id": "00000000-0000-0000-0000-000000000007",
              "state": "ready", "art_url": "https://d1.cloudfront.net/art/a/x.jpg", "failure": null},
             {"id": "00000000-0000-0000-0000-000000000009", "sighting_id": "00000000-0000-0000-0000-000000000007",
              "state": "failed", "art_url": null, "failure": "expired"}]}
            """)]
        let jobs = try await Self.client(recorder).openJobs(accessToken: "t")
        #expect(jobs.map(\.state) == [.ready, .failed])
        #expect(jobs[0].artURL?.absoluteString == "https://d1.cloudfront.net/art/a/x.jpg")
        #expect(jobs[1].failure == "expired")
    }
}
