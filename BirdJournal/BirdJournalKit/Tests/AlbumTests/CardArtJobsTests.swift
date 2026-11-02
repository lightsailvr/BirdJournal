import Foundation
import SwiftData
import Testing
@testable import Album

// Issue #68: scene art on a card. A job starts, is painted, lands or fails; Try again and Retry art are new jobs; the
// last art stays until the new one is ready; nothing here writes another sighting.
@Suite("Card art jobs")
struct CardArtJobsTests {
    static let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    @Test("A card with nothing painted has no scene status")
    func nothing() {
        #expect(CardArt().sceneStatus == .none)
        #expect(CardArt().pendingSceneJob == nil)
    }

    @Test("A started job is pending, then painting, then ready, and shows its art")
    func lifecycle() {
        var art = CardArt()
        art.startSceneJob(id: Self.first)
        #expect(art.sceneStatus == .pending)
        #expect(art.job == ArtJob(id: Self.first, kind: .scene, state: .queued, attempts: 1))
        art.sceneJobPainting(id: Self.first)
        #expect(art.job?.state == .painting)
        #expect(art.sceneStatus == .pending)
        let result = art.sceneJobReady(id: Self.first, path: "art-1.jpg")
        #expect(result.applied && result.replaced == nil)
        #expect(art.scene == ArtImage(path: "art-1.jpg", state: .ready))
        #expect(art.job == ArtJob(id: Self.first, kind: .scene, state: .ready, attempts: 1))
        #expect(art.pendingSceneJob == nil)
        #expect(art.sceneStatus == .ready(showsPackArt: false))
    }

    @Test("Try again keeps the last art until the new painting is ready, then replaces it")
    func tryAgainKeepsTheLastArt() {
        var art = CardArt(scene: ArtImage(path: "art-1.jpg", state: .ready), job: nil)
        art.startSceneJob(id: Self.second)
        #expect(art.scene?.path == "art-1.jpg")
        #expect(art.sceneStatus == .pending)
        let result = art.sceneJobReady(id: Self.second, path: "art-2.jpg")
        #expect(result.replaced == "art-1.jpg")
        #expect(art.scene?.path == "art-2.jpg")
    }

    @Test("Retries and Try again count as attempts on the same card")
    func attempts() {
        var art = CardArt()
        art.startSceneJob(id: Self.first)
        art.sceneJobFailed(id: Self.first)
        art.startSceneJob(id: Self.second)
        #expect(art.job?.attempts == 2)
        #expect(art.job?.id == Self.second)
        art.sceneJobReady(id: Self.second, path: "art.jpg")
        art.startSceneJob(id: UUID())
        #expect(art.job?.attempts == 3)
    }

    @Test("A failed job offers Retry art; Keep current art dismisses it and the card stays as it was")
    func failure() {
        var art = CardArt(scene: ArtImage(path: "art-1.jpg", state: .ready))
        art.startSceneJob(id: Self.first)
        art.sceneJobFailed(id: Self.first)
        #expect(art.sceneStatus == .failed)
        #expect(art.scene?.path == "art-1.jpg")
        art.keepCurrentArt()
        #expect(art.job == nil)
        #expect(art.sceneStatus == .ready(showsPackArt: false))
    }

    @Test("A result for a job the card no longer waits on changes nothing")
    func staleResults() {
        var art = CardArt()
        art.startSceneJob(id: Self.second)
        #expect(!art.sceneJobReady(id: Self.first, path: "stale.jpg").applied)
        art.sceneJobFailed(id: Self.first)
        art.sceneJobDropped(id: Self.first)
        #expect(art.job?.id == Self.second && art.job?.state == .queued)
        #expect(art.scene == nil)
    }

    @Test("Use pack art keeps the painting on file; a newly painted one shows again")
    func usePackArt() {
        var art = CardArt(scene: ArtImage(path: "art-1.jpg", state: .ready))
        art.prefersPackArt = true
        #expect(art.sceneStatus == .ready(showsPackArt: true))
        art.startSceneJob(id: Self.first)
        art.sceneJobReady(id: Self.first, path: "art-2.jpg")
        #expect(!art.prefersPackArt)
    }

    @Test("A refused or lost job leaves nothing under way")
    func dropped() {
        var art = CardArt()
        art.startSceneJob(id: Self.first)
        art.sceneJobDropped(id: Self.first)
        #expect(art == CardArt())
    }

    @Test("The art state survives the album: a pending job, then a ready painting, on the one sighting")
    @MainActor
    func persisted() throws {
        let container = try AlbumSchema.makeContainer(inMemory: true)
        let context = container.mainContext
        let sighting = Sighting(speciesID: "Haemorhous mexicanus_House Finch", confirmedAt: .now, soundConfidence: 0.8, frameImagePath: "frame.jpg", source: .glasses)
        context.insert(sighting)
        sighting.art.startSceneJob(id: Self.first)
        try context.save()
        let fetched = try #require(try context.fetch(FetchDescriptor<Sighting>()).first)
        #expect(fetched.art.pendingSceneJob?.id == Self.first)
        fetched.art.sceneJobReady(id: Self.first, path: "art-1.jpg")
        try context.save()
        #expect(try context.fetch(FetchDescriptor<Sighting>()).count == 1)
        #expect(fetched.filePaths == ["frame.jpg", "art-1.jpg"])
    }
}
