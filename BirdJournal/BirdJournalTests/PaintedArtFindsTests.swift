import Album
import Foundation
import SwiftData
import Testing
@testable import BirdJournal

// Issue #70: painted art in finds, from the phone. When the art a published card shows changes, its find is put again
// with the painting's key; the phone says it has a painting only once that put has gone, so the server (which keeps a
// painting only while a find shows it) never deletes one its find is about to show. A photo painting waits for Approve
// or Keep original before it is acknowledged.
#if DEBUG
@MainActor
@Suite("Painted art in finds")
struct PaintedArtFindsTests {
    let container: ModelContainer
    let frames: FrameStore
    let artClient = FakeArtClient(behaviour: .paints)
    let circles = FindRecorder()
    let art: ArtJobs
    let outbox: FindOutbox
    let network = Network()
    /// What the art server had been told it has when each find put went.
    let receivedAtPut = Log()

    final class Network { var online = true }
    final class Log { var entries: [[UUID]] = [] }

    init() throws {
        container = try AlbumSchema.makeContainer(inMemory: true)
        frames = FrameStore(directory: URL.temporaryDirectory.appending(path: "PaintedArtFindsTests-\(UUID().uuidString)", directoryHint: .isDirectory))
        let account = FakeAccount.session(signedIn: true)
        art = ArtJobs(account: account, client: artClient, frames: frames, container: container)
        art.undoGrace = .zero
        art.preparePhoto = { data, _ in data }
        let container = container
        let network = network
        outbox = FindOutbox(
            account: account, client: circles, fileURL: nil, sharing: { .automatic },
            payload: { identifier, legendary in
                var descriptor = FetchDescriptor<Sighting>(predicate: #Predicate { $0.identifier == identifier })
                descriptor.fetchLimit = 1
                guard let sighting = try? container.mainContext.fetch(descriptor).first else { return nil }
                var input = FindPolicyTests.input(isLegendary: legendary)
                input.paintedArtKey = sighting.art.shownPaintingKey
                return FindPolicy.find(for: input, sharing: .automatic)
            },
            isOnline: { network.online }
        )
        // As the app wires them (BirdJournalApp).
        let outbox = outbox
        let artClient = artClient
        let log = receivedAtPut
        art.artChanged = { identifier in
            outbox.changed(identifier)
            await outbox.flush()
            log.entries.append(artClient.received)
        }
        art.holdsReceipt = { outbox.isWaitingToPublish($0) }
    }

    func publishedSighting() async throws -> Sighting {
        let path = try frames.write(jpeg: Data("original glasses photo".utf8))
        let sighting = Sighting(speciesID: "Sayornis nigricans_Black Phoebe", confirmedAt: .now, soundConfidence: 0.8, frameImagePath: path, source: .glasses)
        container.mainContext.insert(sighting)
        try container.mainContext.save()
        outbox.added(sighting.identifier, isLegendary: false)
        await outbox.flush()
        #expect(circles.puts[sighting.identifier]?.art?.kind == "pack")
        return sighting
    }

    func painted(_ key: String?) -> FindPolicy.Find.Art? {
        key.map { .init(kind: "painted", key: $0, fallback: .init(kind: "pack", key: "packs/us-ca-la/sayornis-nigricans.jpg")) }
    }

    @Test("A landed scene painting is put on the find, and only then does the phone say it has it")
    func sceneArtPutBeforeReceipt() async throws {
        let sighting = try await publishedSighting()
        await art.paintAgain(sighting)
        let job = try #require(sighting.art.job)
        let key = try #require(sighting.art.scene?.serverKey)
        #expect(circles.puts[sighting.identifier]?.art == painted(key))
        #expect(receivedAtPut.entries == [[]], "the put went before the receipt")
        #expect(artClient.received == [job.id])
    }

    @Test("While the find's put waits for the network the painting isn't acknowledged; the next refresh does it after")
    func receiptWaitsForThePut() async throws {
        let sighting = try await publishedSighting()
        network.online = false
        await art.paintAgain(sighting)
        let job = try #require(sighting.art.job)
        #expect(sighting.art.sceneStatus == .ready(showsPackArt: false))
        #expect(outbox.isWaitingToPublish(sighting.identifier))
        #expect(artClient.received.isEmpty)
        await art.refresh()
        #expect(artClient.received.isEmpty, "still waiting to put")

        network.online = true
        await outbox.flush()
        #expect(circles.puts[sighting.identifier]?.art == painted(sighting.art.scene?.serverKey))
        await art.refresh()
        #expect(artClient.received == [job.id])
    }

    @Test("Use pack art puts the find with pack art, and back puts the painting again")
    func usePackArt() async throws {
        let sighting = try await publishedSighting()
        await art.paintAgain(sighting)
        let key = sighting.art.scene?.serverKey
        await art.setShowsPackArt(true, on: sighting).value
        #expect(circles.puts[sighting.identifier]?.art == .init(kind: "pack", key: "packs/us-ca-la/sayornis-nigricans.jpg"))
        await art.setShowsPackArt(false, on: sighting).value
        #expect(circles.puts[sighting.identifier]?.art == painted(key))
    }

    @Test("A photo painting waits for the birder: Approve puts it on the find, then acknowledges it")
    func approvePhotoArt() async throws {
        let sighting = try await publishedSighting()
        let frame = try #require(sighting.frameImagePath)
        await art.paintPhoto(sighting, from: frame)
        let job = try #require(sighting.art.photoJob)
        #expect(circles.puts[sighting.identifier]?.art?.kind == "pack", "a preview isn't on the card")
        #expect(artClient.received.isEmpty)
        await art.refresh()
        #expect(artClient.received.isEmpty, "a refresh leaves an undecided painting on the server")

        await art.approvePhotoArt(sighting).value
        #expect(circles.puts[sighting.identifier]?.art == painted(sighting.art.photo?.serverKey))
        #expect(receivedAtPut.entries.last == [])
        #expect(artClient.received == [job.id])
    }

    @Test("Keep original acknowledges the photo painting and leaves the find as it was")
    func keepOriginal() async throws {
        let sighting = try await publishedSighting()
        let frame = try #require(sighting.frameImagePath)
        await art.paintPhoto(sighting, from: frame)
        let job = try #require(sighting.art.photoJob)
        let calls = circles.calls.count
        await art.keepOriginalPhoto(sighting).value
        #expect(artClient.received == [job.id])
        #expect(circles.calls.count == calls, "nothing to put")
        #expect(circles.puts[sighting.identifier]?.art?.kind == "pack")
    }

    @Test("A private birder's painting is acknowledged at once: no find to put")
    func privateBirder() async throws {
        let path = try frames.write(jpeg: Data("original glasses photo".utf8))
        let sighting = Sighting(speciesID: "Sayornis nigricans_Black Phoebe", confirmedAt: .now, soundConfidence: 0.8, frameImagePath: path, source: .glasses)
        container.mainContext.insert(sighting)
        try container.mainContext.save()
        await art.paintAgain(sighting)
        #expect(circles.calls.isEmpty)
        #expect(artClient.received == [try #require(sighting.art.job?.id)])
    }
}
#endif
