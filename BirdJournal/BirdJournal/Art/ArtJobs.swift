import Album
import Foundation
import Observation
import OSLog
import SwiftData

/// Scene art from the phone's side (issue #68, ADR-0003): after an add with a glasses photo by a signed-in birder, the
/// photo leaves with its faces blurred and its metadata stripped (`ArtPhoto`) for an art job; the result comes back by
/// polling (on launch, on returning to the app, and while a pending card is open; the silent push joins with #63's
/// device tokens), is downloaded and stored with the sighting. Try again and Retry art are new jobs for the same
/// sighting; the last art stays until the new one is ready.
///
/// Photo art (issue #69) rides the same jobs: the birder picks the card's glasses photo or a photo from the library
/// (attached to the card as an original, a file of its own that nothing ever writes over), confirms the bird is the
/// card's species, and the photo leaves prepared the same way. The painting comes back as a preview beside its original
/// for Approve, Keep original or Try again. At the public launch photo art and repainted scene art come out of the
/// day's allowance (`allowance`, "N left today").
///
/// The job is written to the sighting before anything goes over the network, so a pending card survives a killed app,
/// no connection or a painting machine that is off for days: the next refresh picks it up where it stopped (creating
/// a job is idempotent, by the phone's own job id). Nothing here ever inserts a sighting: every change is to the one
/// sighting's `art`, so a retry can never duplicate a card.
@MainActor
@Observable
final class ArtJobs {
    /// What the server's auto-paint rule and the painting need to know about a card.
    struct CardFacts: Equatable {
        var legendary: Bool
        /// The card's set's pack id, whose edition lights the painting.
        var edition: String?
    }

    let account: AccountSession
    @ObservationIgnored private let client: ArtClient?
    @ObservationIgnored private let frames: FrameStore
    @ObservationIgnored private let container: ModelContainer
    /// Read when a job is created; the app reads them from the packs and the collection.
    @ObservationIgnored var cardFacts: (Sighting) -> CardFacts = { _ in CardFacts(legendary: false, edition: nil) }
    /// An add is left alone this long first, so an add undone in its six-second window never sends a photo.
    @ObservationIgnored var undoGrace: Duration = .seconds(7)
    /// The photo as it leaves the phone; tests swap in a stub. A library photo is scaled down too (`maxSide`).
    @ObservationIgnored var preparePhoto: @Sendable (Data, CGFloat?) throws -> Data = { try ArtPhoto.prepare(jpeg: $0, maxSide: $1).jpeg }
    /// Today's paintings on request as the server last said; nil until asked.
    private(set) var allowance: ArtAllowance?
    /// Why the last request for a painting was refused, for the card to say; nil once it has.
    var refusal: String?
    @ObservationIgnored private var driving: Set<UUID> = []
    private let log = Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "art")

    init(account: AccountSession, client: ArtClient?, frames: FrameStore, container: ModelContainer) {
        self.account = account
        self.client = client
        self.frames = frames
        self.container = container
    }

    /// Whether this build can ask for art now: an art server and a signed-in birder.
    var isAvailable: Bool { client != nil && account.isSignedIn }

    // The birder.

    /// After an add (`RunSightings`): scene art for a sighting with a glasses photo, once its undo window has passed.
    func requestAfterAdd(_ sighting: Sighting) {
        guard isAvailable, sighting.frameImagePath != nil else { return }
        let identifier = sighting.identifier
        Task {
            try? await Task.sleep(for: undoGrace)
            // Fetched again, not the object from the add: an undone add's object is detached from the album, and
            // reading it would fault.
            guard let current = self.sighting(identifier), current.art.job == nil, current.art.scene == nil else { return }
            await start(current, requested: false)
        }
    }

    /// Try again (on ready scene art) or Retry art (on a failure): a new job for the same sighting.
    func paintAgain(_ sighting: Sighting) async {
        await start(sighting, requested: true)
    }

    /// Photo art from `source`, a photo already on the card (the glasses photo or an attached original), after the
    /// birder confirmed the bird in it is the card's species. A photo job of its own: a scene painting under way goes on.
    func paintPhoto(_ sighting: Sighting, from source: String) async {
        guard isAvailable, sighting.art.pendingPhotoJob == nil, isAlive(sighting) else { return }
        sighting.art.startPhotoJob(id: UUID(), source: source)
        save(sighting)
        guard let job = sighting.art.pendingPhotoJob else { return }
        await drive(sighting, job: job, known: nil, requested: true)
    }

    /// Try again on photo art waiting for approval, or Retry art after it failed: a new job from the same original.
    func paintPhotoAgain(_ sighting: Sighting) async {
        guard let source = sighting.art.photoJob?.source ?? sighting.art.photoPreview?.source else { return }
        await paintPhoto(sighting, from: source)
    }

    /// A photo from the library attached to the card as an original (spec v2 story 55): written as a file of its own,
    /// byte for byte as the library gave it, and never written over. Returns its path.
    func attachPhoto(_ data: Data, to sighting: Sighting) throws -> String {
        let path = try frames.write(jpeg: data)
        sighting.attachedPhotoPaths.append(path)
        save(sighting)
        return path
    }

    /// Approve: the waiting painting becomes the card's art, labelled "AI-embellished from your photo".
    func approvePhotoArt(_ sighting: Sighting) {
        let replaced = sighting.art.approvePhotoArt()
        save(sighting)
        if let replaced { try? FileManager.default.removeItem(at: frames.url(for: replaced)) }
    }

    /// Keep original: the waiting painting goes; the original photo and the card's art stay as they were.
    func keepOriginalPhoto(_ sighting: Sighting) {
        let discarded = sighting.art.keepOriginalPhoto()
        save(sighting)
        if let discarded { try? FileManager.default.removeItem(at: frames.url(for: discarded)) }
    }

    /// Keep current art after a failed photo painting.
    func keepCurrentPhotoArt(_ sighting: Sighting) {
        sighting.art.keepCurrentPhotoArt()
        save(sighting)
    }

    /// Asks the server how many paintings on request are left today.
    func refreshAllowance() async {
        guard isAvailable, let client else { return }
        if let allowance = try? await account.withAccessToken(doing: "check your paintings", { try await client.allowance(accessToken: $0) }) {
            self.allowance = allowance
        }
    }

    /// "Use pack art", or back to the painting.
    func setShowsPackArt(_ showsPackArt: Bool, on sighting: Sighting) {
        sighting.art.prefersPackArt = showsPackArt
        save(sighting)
    }

    /// Keep current art: the failure is dismissed and the card stays as it is.
    func keepCurrentArt(_ sighting: Sighting) {
        sighting.art.keepCurrentArt()
        save(sighting)
    }

    // Polling.

    /// Every pending job: finished ones land on their cards, unsent ones are sent. Server jobs no card waits on any
    /// more (an undone add, a dismissed failure) are acknowledged, so their art leaves the server.
    func refresh() async {
        guard isAvailable, let client else { return }
        let pending = pendingSightings()
        do {
            let open = try await account.withAccessToken(doing: "check your artwork") { try await client.openJobs(accessToken: $0) }
            for sighting in pending {
                for job in [sighting.art.pendingSceneJob, sighting.art.pendingPhotoJob].compactMap({ $0 }) {
                    await drive(sighting, job: job, known: open.first { $0.id == job.id })
                }
            }
            let waitedOn = Set(pending.flatMap { [$0.art.job?.id, $0.art.photoJob?.id].compactMap { $0 } })
            for orphan in open where !waitedOn.contains(orphan.id) && (orphan.state == .ready || orphan.state == .failed) {
                try? await account.withAccessToken(doing: "check your artwork") { try await client.received(jobID: orphan.id, accessToken: $0) }
            }
        } catch {
            log.info("art refresh failed, the cards stay pending: \(String(describing: error), privacy: .public)")
        }
    }

    /// One card's pending jobs (an open card polls its own).
    func refresh(_ sighting: Sighting) async {
        guard isAvailable else { return }
        for job in [sighting.art.pendingSceneJob, sighting.art.pendingPhotoJob].compactMap({ $0 }) {
            await drive(sighting, job: job, known: nil)
        }
    }

    // Internals.

    private func start(_ sighting: Sighting, requested: Bool) async {
        guard isAvailable, sighting.frameImagePath != nil, sighting.art.pendingSceneJob == nil, isAlive(sighting) else { return }
        sighting.art.startSceneJob(id: UUID())
        save(sighting)
        guard let job = sighting.art.pendingSceneJob else { return }
        await drive(sighting, job: job, known: nil, requested: requested)
    }

    /// Moves one job on as far as it goes now: create it if the server doesn't have it, upload and submit it if it
    /// waits for its photo, and land or fail it if it's done. Any network failure leaves it pending for the next try.
    private func drive(_ sighting: Sighting, job: ArtJob, known: RemoteArtJob?, requested: Bool? = nil) async {
        guard let client, !driving.contains(job.id) else { return }
        // Resumed after a relaunch, a job after the first is one the birder asked for; photo art always is.
        let requested = requested ?? (job.kind == .photo || job.attempts > 1)
        driving.insert(job.id)
        defer { driving.remove(job.id) }
        do {
            var remote: RemoteArtJob
            if let known {
                remote = known
            } else {
                do {
                    remote = try await call { try await client.job(id: job.id, accessToken: $0) }
                } catch ArtClientError.notFound {
                    remote = try await create(sighting, job: job, requested: requested)
                }
            }
            if remote.state == .awaitingUpload {
                let upload: RemoteArtJob.Upload
                if let given = remote.upload {
                    upload = given
                } else {
                    guard let fresh = try await create(sighting, job: job, requested: requested).upload else { return }
                    upload = fresh
                }
                guard isAlive(sighting), let path = job.kind == .photo ? job.source : sighting.frameImagePath else { return }
                // Read, never written: the prepared photo is a new JPEG in memory, and the original stays as it is.
                let original = try Data(contentsOf: frames.url(for: path))
                let maxSide: CGFloat? = job.kind == .photo ? ArtPhoto.libraryMaxSide : nil
                let photo = try await Task.detached(priority: .utility) { [preparePhoto] in try preparePhoto(original, maxSide) }.value
                try await client.upload(photo, to: upload)
                remote = try await call { try await client.submit(jobID: job.id, accessToken: $0) }
                // A painting machine that is quick (or a fake one) may be done already.
                if remote.state == .queued { remote = try await call { try await client.job(id: job.id, accessToken: $0) } }
            }
            try await land(remote, on: sighting, job: job)
        } catch ArtClientError.notEligible {
            drop(job, on: sighting)
        } catch ArtClientError.allowanceSpent {
            drop(job, on: sighting)
            refusal = Self.allowanceSpentMessage(allowance)
            await refreshAllowance()
        } catch {
            log.info("art job \(job.id, privacy: .public) stays pending: \(String(describing: error), privacy: .public)")
        }
    }

    private func create(_ sighting: Sighting, job: ArtJob, requested: Bool) async throws -> RemoteArtJob {
        guard let client else { throw ArtClientError.server(0) }
        let facts = cardFacts(sighting)
        let request = ArtJobRequest(
            id: job.id, sightingID: sighting.identifier, scientificName: sighting.scientificName, edition: facts.edition,
            legendary: facts.legendary, rarity: sighting.rarity?.label.rawValue, requested: requested
        )
        var kinded = request
        kinded.kind = job.kind.rawValue
        let remote = try await call { try await client.createJob(kinded, accessToken: $0) }
        if requested { await refreshAllowance() }
        return remote
    }

    private func drop(_ job: ArtJob, on sighting: Sighting) {
        switch job.kind {
        case .scene: sighting.art.sceneJobDropped(id: job.id)
        case .photo: sighting.art.photoJobDropped(id: job.id)
        }
        save(sighting)
    }

    /// What the card says when today's paintings are used up.
    static func allowanceSpentMessage(_ allowance: ArtAllowance?) -> String {
        let daily = allowance?.daily.map { "all \($0)" } ?? "all"
        return "You've used \(daily) of today's paintings. Try again tomorrow."
    }

    private func land(_ remote: RemoteArtJob, on sighting: Sighting, job: ArtJob) async throws {
        guard let client, isAlive(sighting) else { return }
        switch remote.state {
        case .awaitingUpload, .queued:
            return
        case .painting:
            switch job.kind {
            case .scene: sighting.art.sceneJobPainting(id: job.id)
            case .photo: sighting.art.photoJobPainting(id: job.id)
            }
            save(sighting)
        case .ready:
            guard let url = remote.artURL else { return }
            let painting = try await client.download(url)
            // Always a new file: a painting never takes the original's place on disk.
            let path = try frames.write(jpeg: painting)
            let result = switch job.kind {
            case .scene: sighting.art.sceneJobReady(id: job.id, path: path)
            case .photo: sighting.art.photoJobReady(id: job.id, path: path)
            }
            save(sighting)
            if !result.applied { try? FileManager.default.removeItem(at: frames.url(for: path)) }
            if let replaced = result.replaced { try? FileManager.default.removeItem(at: frames.url(for: replaced)) }
            try await call { try await client.received(jobID: job.id, accessToken: $0) }
        case .failed:
            log.info("art job \(job.id, privacy: .public) failed: \(remote.failure ?? "unknown", privacy: .public)")
            switch job.kind {
            case .scene: sighting.art.sceneJobFailed(id: job.id)
            case .photo: sighting.art.photoJobFailed(id: job.id)
            }
            save(sighting)
            try await call { try await client.received(jobID: job.id, accessToken: $0) }
        }
    }

    private func call<T>(_ body: (String) async throws -> T) async throws -> T {
        try await account.withAccessToken(doing: "send your artwork", body)
    }

    private func sighting(_ identifier: UUID) -> Sighting? {
        var descriptor = FetchDescriptor<Sighting>(predicate: #Predicate { $0.identifier == identifier })
        descriptor.fetchLimit = 1
        return try? container.mainContext.fetch(descriptor).first
    }

    /// Still in the album: a card deleted while its job was on the network is left alone (its server job is
    /// acknowledged by the next refresh as an orphan).
    private func isAlive(_ sighting: Sighting) -> Bool {
        sighting.modelContext != nil && !sighting.isDeleted
    }

    private func pendingSightings() -> [Sighting] {
        ((try? container.mainContext.fetch(FetchDescriptor<Sighting>())) ?? []).filter { $0.art.pendingSceneJob != nil || $0.art.pendingPhotoJob != nil }
    }

    private func save(_ sighting: Sighting) {
        do {
            try sighting.modelContext?.save()
        } catch {
            log.error("couldn't save the card's art: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension ArtJobs {
    /// The app's art jobs: the bundled server's API, or none when the build has no server. In debug builds
    /// `-fakeArt paints|pending|fails`, or `-fakeAccount` alone (painting), swaps in the in-memory fake.
    static func forApp(account: AccountSession, frames: FrameStore, container: ModelContainer) -> ArtJobs {
        #if DEBUG
        let defaults = UserDefaults.standard
        if let mode = defaults.string(forKey: "fakeArt") ?? defaults.string(forKey: "fakeAccount").map({ _ in "paints" }) {
            let fake = FakeArtClient(behaviour: .init(rawValue: mode) ?? .paints)
            // `-fakeArtDaily 5`: the public launch's allowance (issue #69).
            if defaults.object(forKey: "fakeArtDaily") != nil { fake.daily = defaults.integer(forKey: "fakeArtDaily") }
            return ArtJobs(account: account, client: fake, frames: frames, container: container)
        }
        #endif
        guard let server = AccountServer.bundled() else { return ArtJobs(account: account, client: nil, frames: frames, container: container) }
        return ArtJobs(account: account, client: HTTPArtClient(baseURL: server.apiURL), frames: frames, container: container)
    }
}
