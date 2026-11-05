import Album
import Foundation
import Pack
import SwiftData
import SwiftUI
import Testing
@testable import BirdJournal

#if DEBUG
// Issue #137: scene art, photo art and the watercolour pack art are retired. A sighting that has them still opens, shows
// none of it and offers nothing, and none of it reaches a find.
@Suite("Retired art", .serialized)
@MainActor
struct RetiredArtTests {
    static let storedArt = CardArt(
        prefersPackArt: true,
        scene: ArtImage(path: "scene.jpg", state: .ready, serverKey: "art/ada/scene.jpg"),
        photo: ArtImage(path: "photo.jpg", state: .ready, serverKey: "art/ada/photo.jpg"),
        photoPreview: ArtImage(path: "preview.jpg", state: .preview),
        job: ArtJob(id: UUID(), kind: .scene, state: .painting, attempts: 2),
        photoJob: ArtJob(id: UUID(), kind: .photo, state: .failed, attempts: 1)
    )

    @Test("a sighting with stored art opens with no art on the page and nothing to ask for")
    func sightingOpens() async throws {
        let harness = try ScreenAccessibilityTests.Harness()
        let sighting = try #require(harness.newest)
        sighting.art = Self.storedArt
        try harness.album.mainContext.save()
        let labels = try await ScreenAccessibilityTests.walk(SightingDetailView(id: sighting.persistentModelID), harness: harness) { labels in
            labels.contains("About this bird")
        }
        #expect(labels.contains("About this bird"), "the page opened: \(labels)")
        for retired in ["Art", "Try again", "Retry art", "Use pack art", "Use painted art", "Keep current art", "Paint this scene", "Paint this photo"] {
            #expect(!labels.contains(retired), "\(retired) is gone: \(labels)")
        }
        #expect(!labels.contains { $0.hasPrefix("Card art") || $0.contains("left today") || $0.contains("Artwork is on its way") }, "\(labels)")
        #expect(sighting.artState != nil, "opening it changes nothing")
    }

    @Test("a stored painting never goes on a find: the find shows the patch")
    func storedPaintingStaysOffTheFind() throws {
        let library = PackLibrary(bundled: try SpeciesPack.bundled(), storage: PackStorage(directory: URL.temporaryDirectory.appending(path: "RetiredArtPacks-\(UUID().uuidString)")), indexURL: PackIndex.defaultURL)
        let sighting = Sighting(speciesID: "Sayornis nigricans_Black Phoebe", confirmedAt: .now, location: Coordinate(latitude: 34.1365, longitude: -118.2942, accuracy: 15), soundConfidence: 0.8, source: .glasses)
        sighting.art = Self.storedArt
        let input = FindOutbox.input(of: sighting, isNewPatch: true, packs: library, places: PlaceNames())
        let find = try #require(FindPolicy.find(for: input, sharing: .automatic))
        #expect(find.art?.kind == "pack")
        #expect(find.art?.key.hasPrefix("packs/\(PackIndex.bundledPackID)/patch/") == true, "\(String(describing: find.art))")
    }

    @Test("the feed draws a stored thumbnail only when it is a patch's")
    func onlyAPatchThumbnailIsDrawn() {
        let url = URL(string: "https://art.example/x")!
        #expect(FeedItem.Art(kind: "pack", key: "packs/us-ca-la/patch/sayornis-nigricans.png", url: url).patchThumbnailURL == url)
        #expect(FeedItem.Art(kind: "pack", key: "packs/us-ca-la/sayornis-nigricans.jpg", url: url).patchThumbnailURL == nil, "a watercolour's")
        #expect(FeedItem.Art(kind: "pack", key: "packs/us-ca-la/patch/x.png", url: nil).patchThumbnailURL == nil, "no CDN yet")
    }
}
#endif
