import Foundation
import SwiftData
import Testing
@testable import Album

// Issue #137 retired scene art and photo art with no schema change: `artState` stays JSON, and nothing writes it for a new
// sighting. A sighting stored before then still opens, and its paintings still go with it.
@Suite("Stored art")
struct StoredArtTests {
    /// Art as issues #68 to #70 wrote it: `CardArt` through `JSONEncoder`, every field set.
    static let everyField = Data(
        """
        {"prefersPackArt":true,\
        "scene":{"path":"scene.jpg","state":"ready","serverKey":"art/ada/scene.jpg"},\
        "photo":{"path":"photo.jpg","state":"ready","source":"frame.jpg","serverKey":"art/ada/photo.jpg"},\
        "photoPreview":{"path":"preview.jpg","state":"preview","source":"mine.heic"},\
        "job":{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":"scene","state":"painting","attempts":2},\
        "photoJob":{"id":"7F9619FF-8B86-D011-B42D-00C04FC964FF","kind":"photo","state":"failed","attempts":1,"source":"mine.heic"}}
        """.utf8
    )
    /// As #68 first wrote it, before the photo fields and the server key.
    static let earliest = Data(#"{"prefersPackArt":false,"scene":{"path":"scene.jpg","state":"ready"}}"#.utf8)

    static func sighting(artState: Data?) -> Sighting {
        let sighting = Sighting(speciesID: "Haemorhous mexicanus_House Finch", confirmedAt: .now, soundConfidence: 0.8, frameImagePath: "frame.jpg", source: .glasses)
        sighting.artState = artState
        return sighting
    }

    @Test("art stored with every field decodes, job under way included")
    func everyFieldDecodes() {
        let art = Self.sighting(artState: Self.everyField).art
        #expect(art.prefersPackArt)
        #expect(art.scene == ArtImage(path: "scene.jpg", state: .ready, serverKey: "art/ada/scene.jpg"))
        #expect(art.photo == ArtImage(path: "photo.jpg", state: .ready, source: "frame.jpg", serverKey: "art/ada/photo.jpg"))
        #expect(art.photoPreview == ArtImage(path: "preview.jpg", state: .preview, source: "mine.heic"))
        #expect(art.job?.kind == .scene && art.job?.state == .painting && art.job?.attempts == 2)
        #expect(art.photoJob?.kind == .photo && art.photoJob?.state == .failed && art.photoJob?.source == "mine.heic")
    }

    @Test("art stored before the later fields decodes")
    func earliestDecodes() {
        let art = Self.sighting(artState: Self.earliest).art
        #expect(art.scene == ArtImage(path: "scene.jpg", state: .ready))
        #expect(art.photo == nil && art.photoPreview == nil && art.job == nil && art.photoJob == nil)
    }

    @Test("art that can't be read counts as none, and the sighting still opens")
    func unreadableIsNone() {
        #expect(Self.sighting(artState: Data("not json".utf8)).art == CardArt())
        #expect(Self.sighting(artState: nil).art == CardArt())
    }

    @Test("a new sighting has no art state")
    func newSightingHasNone() {
        let sighting = Sighting(speciesID: "Haemorhous mexicanus_House Finch", confirmedAt: .now, soundConfidence: 0.8, source: .glasses)
        #expect(sighting.artState == nil)
    }

    @Test("the paintings are among the files that go with the sighting; the originals stay separate entries")
    func paintingsGoWithTheSighting() {
        let sighting = Self.sighting(artState: Self.everyField)
        sighting.attachedPhotoPaths = ["mine.heic"]
        #expect(sighting.filePaths == ["frame.jpg", "mine.heic", "scene.jpg", "photo.jpg", "preview.jpg"])
    }

    @Test("a store holding art state reopens with it, under the same schema")
    @MainActor
    func storeReopens() throws {
        let folder = URL.temporaryDirectory.appending(path: "album-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "album.store")
        do {
            let album = try AlbumSchema.makeContainer(at: url)
            album.mainContext.insert(Self.sighting(artState: Self.everyField))
            try album.mainContext.save()
        }
        let album = try AlbumSchema.makeContainer(at: url)
        let reopened = try #require(try album.mainContext.fetch(Sighting.newestFirst()).first)
        #expect(reopened.artState == Self.everyField)
        #expect(reopened.art.scene?.path == "scene.jpg")
    }
}
