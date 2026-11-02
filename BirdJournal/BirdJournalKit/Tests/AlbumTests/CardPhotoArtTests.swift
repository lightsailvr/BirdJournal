import Foundation
import Testing
@testable import Album

// Issue #69: photo art on a card. The birder's photo is painted, waits beside its original, and is approved, let go
// (Keep original) or painted again; the original is only ever named, never replaced.
@Suite("Card photo art")
struct CardPhotoArtTests {
    static let first = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
    static let second = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!

    @Test("A photo job is pending, then waits for approval beside its original")
    func lifecycle() {
        var art = CardArt()
        #expect(art.photoStatus == .none)
        art.startPhotoJob(id: Self.first, source: "original.jpg")
        #expect(art.photoStatus == .pending)
        #expect(art.photoJob == ArtJob(id: Self.first, kind: .photo, state: .queued, attempts: 1, source: "original.jpg"))
        art.photoJobPainting(id: Self.first)
        #expect(art.pendingPhotoJob?.state == .painting)
        let result = art.photoJobReady(id: Self.first, path: "painted.jpg")
        #expect(result.applied && result.replaced == nil)
        #expect(art.photoStatus == .preview(path: "painted.jpg", source: "original.jpg"))
        // Not on the card until approved.
        #expect(art.photo == nil)
    }

    @Test("Approve puts the painting on the card and keeps its source")
    func approve() {
        var art = CardArt()
        art.startPhotoJob(id: Self.first, source: "original.jpg")
        art.photoJobReady(id: Self.first, path: "painted.jpg")
        #expect(art.approvePhotoArt() == nil)
        #expect(art.photo == ArtImage(path: "painted.jpg", state: .ready, source: "original.jpg"))
        #expect(art.photoPreview == nil)
        #expect(art.photoStatus == .approved)
    }

    @Test("Keep original lets the painting go and leaves the card as it was")
    func keepOriginal() {
        var art = CardArt(photo: ArtImage(path: "approved.jpg", state: .ready, source: "a.jpg"))
        art.startPhotoJob(id: Self.first, source: "b.jpg")
        art.photoJobReady(id: Self.first, path: "painted.jpg")
        #expect(art.keepOriginalPhoto() == "painted.jpg")
        #expect(art.photo == ArtImage(path: "approved.jpg", state: .ready, source: "a.jpg"))
        #expect(art.photoStatus == .approved)
    }

    @Test("Try again keeps the waiting painting until the new one arrives, then replaces it")
    func tryAgain() {
        var art = CardArt()
        art.startPhotoJob(id: Self.first, source: "original.jpg")
        art.photoJobReady(id: Self.first, path: "painted-1.jpg")
        art.startPhotoJob(id: Self.second, source: "original.jpg")
        #expect(art.photoJob?.attempts == 2)
        #expect(art.photoStatus == .pending)
        #expect(art.photoPreview?.path == "painted-1.jpg")
        let result = art.photoJobReady(id: Self.second, path: "painted-2.jpg")
        #expect(result.replaced == "painted-1.jpg")
        #expect(art.photoStatus == .preview(path: "painted-2.jpg", source: "original.jpg"))
    }

    @Test("Approving again replaces the earlier approved painting")
    func approveAgain() {
        var art = CardArt(photo: ArtImage(path: "approved.jpg", state: .ready, source: "a.jpg"))
        art.startPhotoJob(id: Self.first, source: "a.jpg")
        art.photoJobReady(id: Self.first, path: "painted.jpg")
        #expect(art.approvePhotoArt() == "approved.jpg")
        #expect(art.photo?.path == "painted.jpg")
    }

    @Test("A failure offers Retry art; Keep current art dismisses it")
    func failure() {
        var art = CardArt()
        art.startPhotoJob(id: Self.first, source: "original.jpg")
        art.photoJobFailed(id: Self.first)
        #expect(art.photoStatus == .failed)
        art.keepCurrentPhotoArt()
        #expect(art.photoStatus == .none)
        #expect(art.photoJob == nil)
    }

    @Test("A refused job (allowance spent) is dropped")
    func dropped() {
        var art = CardArt()
        art.startPhotoJob(id: Self.first, source: "original.jpg")
        art.photoJobDropped(id: Self.first)
        #expect(art.photoJob == nil)
        #expect(art.photoStatus == .none)
    }

    @Test("A result for another job changes nothing")
    func staleResult() {
        var art = CardArt()
        art.startPhotoJob(id: Self.second, source: "original.jpg")
        #expect(!art.photoJobReady(id: Self.first, path: "stale.jpg").applied)
        #expect(art.photoPreview == nil)
    }

    @Test("Scene and photo jobs are tracked apart")
    func apart() {
        var art = CardArt()
        art.startSceneJob(id: Self.first)
        art.startPhotoJob(id: Self.second, source: "original.jpg")
        #expect(art.sceneStatus == .pending)
        #expect(art.photoStatus == .pending)
        art.sceneJobReady(id: Self.first, path: "scene.jpg")
        #expect(art.photoStatus == .pending)
    }

    @Test("Card art saved before photo art reads back with none")
    func olderState() throws {
        let old = #"{"prefersPackArt":false,"scene":{"path":"s.jpg","state":"ready"},"job":{"id":"00000000-0000-0000-0000-000000000011","kind":"scene","state":"ready","attempts":1}}"#
        let art = try JSONDecoder().decode(CardArt.self, from: Data(old.utf8))
        #expect(art.photoJob == nil && art.photoPreview == nil)
        #expect(art.scene == ArtImage(path: "s.jpg", state: .ready))
    }

    @Test("Every painting and the waiting one go with the sighting")
    func filePaths() {
        let sighting = Sighting(speciesID: "Haemorhous mexicanus_House Finch", confirmedAt: .now, soundConfidence: 0.9, frameImagePath: "frame.jpg", source: .glasses)
        sighting.attachedPhotoPaths = ["original.jpg"]
        sighting.art = CardArt(photo: ArtImage(path: "approved.jpg", state: .ready), photoPreview: ArtImage(path: "waiting.jpg", state: .preview))
        #expect(Set(sighting.filePaths) == ["frame.jpg", "original.jpg", "approved.jpg", "waiting.jpg"])
    }
}
