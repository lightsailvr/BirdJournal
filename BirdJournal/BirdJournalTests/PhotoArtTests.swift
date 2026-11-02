import Album
import CryptoKit
import Foundation
import SwiftData
import Testing
import UIKit
@testable import BirdJournal

// Issue #69: photo art from the phone. A glasses photo or a library photo (attached as an original) goes up prepared;
// the painting waits beside it for Approve, Keep original or Try again; the original is never written over; at the
// public launch photo art comes out of the day's allowance.
@MainActor
@Suite("Photo art")
struct PhotoArtTests {
    let container: ModelContainer
    let frames: FrameStore
    let client: FakeArtClient
    let art: ArtJobs
    let prepared = Data("prepared photo".utf8)
    let library = Data("a photo from the library, as the library gave it".utf8)

    init() throws {
        container = try AlbumSchema.makeContainer(inMemory: true)
        frames = FrameStore(directory: URL.temporaryDirectory.appending(path: "PhotoArtTests-\(UUID().uuidString)", directoryHint: .isDirectory))
        client = FakeArtClient(behaviour: .paints)
        art = ArtJobs(account: FakeAccount.session(signedIn: true), client: client, frames: frames, container: container)
        let prepared = prepared
        art.preparePhoto = { _, _ in prepared }
        art.cardFacts = { _ in ArtJobs.CardFacts(legendary: false, edition: "us-ca-la") }
    }

    func sighting(method: SightingMethod = .heard) throws -> Sighting {
        let path = try frames.write(jpeg: Data("original glasses photo".utf8))
        let sighting = Sighting(speciesID: "Haemorhous mexicanus_House Finch", confirmedAt: .now, soundConfidence: 0.8, frameImagePath: path, source: .glasses, method: method)
        container.mainContext.insert(sighting)
        try container.mainContext.save()
        return sighting
    }

    func digest(_ path: String) throws -> SHA256.Digest {
        SHA256.hash(data: try Data(contentsOf: frames.url(for: path)))
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: frames.url(for: path).path(percentEncoded: false))
    }

    @Test("A library photo is attached as an original, sent prepared, and painted into a preview beside it")
    func libraryPhoto() async throws {
        let sighting = try sighting()
        let original = try art.attachPhoto(library, to: sighting)
        #expect(sighting.attachedPhotoPaths == [original])
        #expect(try Data(contentsOf: frames.url(for: original)) == library)

        await art.paintPhoto(sighting, from: original)

        let request = try #require(client.requests.first)
        #expect(request.kind == .photo)
        #expect(request.requested)
        #expect(request.sightingID == sighting.identifier)
        #expect(client.uploads[request.id] == prepared)
        guard case .preview(let path, let source) = sighting.art.photoStatus else { Issue.record("no preview"); return }
        #expect(source == original)
        #expect(path != original)
        #expect(exists(path))
        // Not the card's art until approved.
        #expect(sighting.art.photo == nil)
        // No find could show it (this card has none), so the server may let it go at once (#70).
        #expect(client.received == [request.id])
    }

    @Test("An attached library photo keeps its own format, named for it")
    func attachedFormat() throws {
        let sighting = try sighting()
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        let png = renderer.pngData { $0.cgContext.fill(CGRect(x: 0, y: 0, width: 8, height: 8)) }
        let path = try art.attachPhoto(png, to: sighting)
        #expect(path.hasSuffix(".png"))
        #expect(try Data(contentsOf: frames.url(for: path)) == png)
        #expect(try art.attachPhoto(library, to: sighting).hasSuffix(".jpg"))
    }

    @Test("The glasses photo can be the source too")
    func glassesPhoto() async throws {
        let sighting = try sighting()
        let frame = try #require(sighting.frameImagePath)
        await art.paintPhoto(sighting, from: frame)
        #expect(sighting.art.photoStatus == .preview(path: try #require(sighting.art.photoPreview?.path), source: frame))
        #expect(sighting.attachedPhotoPaths.isEmpty)
    }

    @Test("The original photo is never overwritten: not by preparing, painting, Try again, approving or keeping it")
    func originalNeverOverwritten() async throws {
        let sighting = try sighting()
        let original = try art.attachPhoto(library, to: sighting)
        let frame = try #require(sighting.frameImagePath)
        let before = (try digest(original), try digest(frame))

        await art.paintPhoto(sighting, from: original)
        await art.paintPhotoAgain(sighting)
        art.approvePhotoArt(sighting)
        await art.paintPhoto(sighting, from: original)
        art.keepOriginalPhoto(sighting)
        await art.paintPhoto(sighting, from: frame)
        art.approvePhotoArt(sighting)

        #expect((try digest(original), try digest(frame)) == before)
        #expect(sighting.attachedPhotoPaths == [original])
        #expect(sighting.frameImagePath == frame)
        let approved = try #require(sighting.art.photo?.path)
        #expect(![original, frame].contains(approved))
        #expect(sighting.art.photo?.source == frame)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<Sighting>()) == 1)
    }

    @Test("Approve puts the painting on the card, labelled as embellished from the birder's photo")
    func approve() async throws {
        let sighting = try sighting()
        let original = try art.attachPhoto(library, to: sighting)
        await art.paintPhoto(sighting, from: original)
        let preview = try #require(sighting.art.photoPreview?.path)
        art.approvePhotoArt(sighting)
        #expect(sighting.art.photoStatus == .approved)
        let card = CardText.Art(sighting: sighting, packArt: nil, reference: nil)
        #expect(card == .photoArt(path: preview))
        #expect(card.label == "AI-embellished from your photo")
    }

    @Test("Keep original lets the painting go and keeps the card's art and the original")
    func keepOriginal() async throws {
        let sighting = try sighting()
        let original = try art.attachPhoto(library, to: sighting)
        await art.paintPhoto(sighting, from: original)
        let preview = try #require(sighting.art.photoPreview?.path)
        art.keepOriginalPhoto(sighting)
        #expect(sighting.art.photoStatus == .none)
        #expect(!exists(preview))
        #expect(exists(original))
        #expect(CardText.Art(sighting: sighting, packArt: nil, reference: nil) == .none)
    }

    @Test("Try again paints a new job from the same original; the earlier preview goes once the new one lands")
    func tryAgain() async throws {
        let sighting = try sighting()
        let original = try art.attachPhoto(library, to: sighting)
        await art.paintPhoto(sighting, from: original)
        let first = try #require(sighting.art.photoPreview?.path)
        await art.paintPhotoAgain(sighting)
        #expect(client.requests.map(\.kind) == [.photo, .photo])
        #expect(Set(client.requests.map(\.id)).count == 2)
        let second = try #require(sighting.art.photoPreview?.path)
        #expect(second != first)
        #expect(!exists(first))
        #expect(sighting.art.photoPreview?.source == original)
        #expect(sighting.art.photoJob?.attempts == 2)
    }

    @Test("A failed painting offers Retry art and Keep current art")
    func failure() async throws {
        client.behaviour = .fails
        let sighting = try sighting()
        await art.paintPhoto(sighting, from: try #require(sighting.frameImagePath))
        #expect(sighting.art.photoStatus == .failed)
        client.behaviour = .paints
        await art.paintPhotoAgain(sighting)
        #expect(sighting.art.photoPreview != nil)
    }

    @Test("Photo art pending with the painting machine off lands on the next refresh, beside a scene job")
    func pendingBesideScene() async throws {
        client.behaviour = .pending
        let sighting = try sighting()
        await art.paintAgain(sighting)
        await art.paintPhoto(sighting, from: try #require(sighting.frameImagePath))
        let scene = try #require(sighting.art.pendingSceneJob)
        let photo = try #require(sighting.art.pendingPhotoJob)
        client.finishQueued(photo.id)
        await art.refresh()
        #expect(sighting.art.photoPreview != nil)
        #expect(sighting.art.sceneStatus == .pending)
        client.finishQueued(scene.id)
        await art.refresh()
        #expect(sighting.art.sceneStatus == .ready(showsPackArt: false))
    }

    @Test("At the public launch each photo painting takes one of the day's; past them the request is refused and said so")
    func allowance() async throws {
        client.daily = 2
        let sighting = try sighting()
        let frame = try #require(sighting.frameImagePath)
        await art.refreshAllowance()
        #expect(art.allowance?.left == 2)
        #expect(CardText.allowanceLine(art.allowance) == "2 left today")

        await art.paintPhoto(sighting, from: frame)
        #expect(art.allowance?.left == 1)
        await art.paintPhotoAgain(sighting)
        #expect(art.allowance?.left == 0)
        #expect(CardText.allowanceLine(art.allowance) == "0 left today")
        let preview = sighting.art.photoPreview

        await art.paintPhotoAgain(sighting)
        #expect(sighting.art.pendingPhotoJob == nil)
        #expect(sighting.art.photoPreview == preview)
        #expect(art.refusal == ArtJobs.Refusal(sighting: sighting.identifier, kind: .photo, message: "You've used all 2 of today's paintings. Try again tomorrow."))
    }

    @Test("In the friends phase there is no allowance to show")
    func friendsPhase() async throws {
        await art.refreshAllowance()
        #expect(art.allowance == .unlimited)
        #expect(CardText.allowanceLine(art.allowance) == nil)
    }

    @Test("Nothing is sent signed out")
    func signedOut() async throws {
        let signedOut = ArtJobs(account: FakeAccount.session(signedIn: false), client: client, frames: frames, container: container)
        let sighting = try sighting()
        await signedOut.paintPhoto(sighting, from: try #require(sighting.frameImagePath))
        #expect(client.requests.isEmpty)
        #expect(sighting.art.photoJob == nil)
    }
}

// The Heard-to-Seen prompt (spec v2, "Method changes on the phone").
@Suite("Did you see it?")
struct DidYouSeeItTests {
    @Test("Attaching a photo to a Heard card asks; a Seen card, or the card's own glasses photo, doesn't")
    func asks() {
        #expect(PhotoArtFlow.asksDidYouSeeIt(method: .heard, attaching: true))
        #expect(!PhotoArtFlow.asksDidYouSeeIt(method: .seen, attaching: true))
        #expect(!PhotoArtFlow.asksDidYouSeeIt(method: .heard, attaching: false))
    }
}
