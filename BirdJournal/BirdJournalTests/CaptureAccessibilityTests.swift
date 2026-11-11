import Album
import Foundation
import Pack
import SwiftData
import SwiftUI
import Testing
@testable import BirdJournal

// Issue #186 (of #185): VoiceOver over the capture's screens, walked in process as `ScreenAccessibilityTests` walks the
// rest (XCUITest lists views SwiftUI hides from VoiceOver): the button and "Seen this run" on the run's page, the camera in
// each of its states, "Name this bird" with its results and its no-match state, and the page of a sighting the birder named.
// Each at the default text size and at the largest accessibility size, where every element must still be reached, labelled,
// and free of middle dots and match scores.
@Suite("Capture accessibility", .serialized)
@MainActor
struct CaptureAccessibilityTests {
    typealias Screens = ScreenAccessibilityTests

    static let allens = NameableBird(speciesID: "Selasphorus sasin_Allen's Hummingbird", scientificName: "Selasphorus sasin", commonName: "Allen's Hummingbird", isInFieldGuide: true)
    static let annas = NameableBird(speciesID: "Calypte anna_Anna's Hummingbird", scientificName: "Calypte anna", commonName: "Anna's Hummingbird", isInFieldGuide: true)

    static func photo() -> CapturedPhoto { CapturedPhoto(data: DebugSeeds.frameJPEG(), takenAt: .now) }

    static func expectNoScore(_ labels: [String], screen: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(!labels.contains { $0.localizedCaseInsensitiveContains("score") || $0.localizedCaseInsensitiveContains("% match") }, "\(screen): \(labels)", sourceLocation: sourceLocation)
    }

    @Test("A run's page: Capture a sighting, and each seen bird above the heard ones in one sentence, with no score", arguments: Screens.sizes)
    func runPage(typeSize: DynamicTypeSize) async throws {
        let harness = try Screens.Harness()
        await harness.run.start()
        // The seeds have an Uncharted Anna's Hummingbird and no Allen's: with no place, one adds to a patch and one sews one.
        try #require(harness.run.addSeen(Self.allens, photo: Self.photo()))
        harness.run.dismissReveal()
        try #require(harness.run.addSeen(Self.annas, photo: Self.photo()))

        let labels = try await Screens.walk(ActiveListeningView(), harness: harness, typeSize: typeSize) { labels in
            labels.contains("Seen this run") && labels.contains { $0.hasPrefix("Anna's Hummingbird, ") }
        }
        await harness.run.stop()

        Screens.expectClean(labels, screen: "Run with seen birds")
        Screens.expectOneWordPerThing(labels, screen: "Run with seen birds")
        Self.expectNoScore(labels, screen: "Run with seen birds")
        #expect(labels.contains("Capture a sighting"), "\(labels)")
        #expect(labels.contains("Seen this run"), "\(labels)")
        #expect(labels.contains("Allen's Hummingbird, Seen, your photo, New patch"), "\(labels)")
        #expect(labels.contains("Anna's Hummingbird, Seen 2 times here, your photo"), "\(labels)")
        let section = try #require(labels.firstIndex(of: "Seen this run"))
        let listening = try #require(labels.firstIndex(of: "Listening for birds…"))
        #expect(section < listening, "above what was heard: \(labels)")
    }

    @Test("The camera: Close, that the run is still listening with its clock, the viewfinder and Take photo", arguments: Screens.sizes)
    func camera(typeSize: DynamicTypeSize) async throws {
        let harness = try Screens.Harness()
        await harness.run.start()
        let camera = StandInCaptureCamera(.ready)
        let labels = try await Screens.walk(CaptureCameraView(camera: camera, taken: { _, _ in }, close: {}), harness: harness, typeSize: typeSize, inStack: false) { labels in
            labels.contains("Viewfinder") && labels.contains { $0.hasPrefix("Still listening") }
        }
        await harness.run.stop()

        Screens.expectClean(labels, screen: "Camera")
        let close = try #require(labels.firstIndex(of: "Close camera"), "\(labels)")
        let pill = try #require(labels.firstIndex { $0.hasPrefix("Still listening, 0 minutes ") }, "\(labels)")
        let viewfinder = try #require(labels.firstIndex(of: "Viewfinder"), "\(labels)")
        let shutter = try #require(labels.firstIndex(of: "Take photo"), "\(labels)")
        #expect(close < pill && pill < viewfinder && viewfinder < shutter, "from the top down: \(labels)")
    }

    @Test("A refused camera says what it is for and how to allow it, and Take photo is still found, dimmed", arguments: Screens.sizes)
    func cameraDenied(typeSize: DynamicTypeSize) async throws {
        let harness = try Screens.Harness()
        let labels = try await Screens.walk(CaptureCameraView(camera: StandInCaptureCamera(.denied), taken: { _, _ in }, close: {}), harness: harness, typeSize: typeSize, inStack: false) { labels in
            labels.contains("Open Settings")
        }
        Screens.expectClean(labels, screen: "Camera refused")
        #expect(labels.contains("Camera access is off"), "\(labels)")
        #expect(labels.contains { $0.contains("photograph a bird you've seen") && $0.contains("Settings > Featherguild") }, "\(labels)")
        #expect(labels.contains("Open Settings"), "\(labels)")
        #expect(labels.contains("Close camera"), "\(labels)")
        #expect(!labels.contains("Viewfinder"), "\(labels)")
        #expect(!labels.contains { $0.hasPrefix("Still listening") }, "no run, no pill: \(labels)")

        let none = try await Screens.walk(CaptureCameraView(camera: StandInCaptureCamera(.unavailable), taken: { _, _ in }, close: {}), harness: harness, typeSize: typeSize, inStack: false) { labels in
            labels.contains("No camera to use")
        }
        Screens.expectClean(none, screen: "No camera")
        #expect(none.contains("No camera to use"), "\(none)")
    }

    @Test("Name this bird: the photo with its time and place, the search, the field guides' birds each in a sentence, and the pinned add", arguments: Screens.sizes)
    func nameThisBird(typeSize: DynamicTypeSize) async throws {
        let harness = try Screens.Harness()
        let labels = try await Screens.walk(NameBirdView(unnamed: try #require(harness.run.capture(Self.photo()))) {}, harness: harness, typeSize: typeSize, inStack: false) { labels in
            labels.contains("In your field guides") && labels.contains { $0.hasPrefix("Allen's Hummingbird, ") }
        }
        Screens.expectClean(labels, screen: "Name this bird")
        Screens.expectOneWordPerThing(labels, screen: "Name this bird")
        Self.expectNoScore(labels, screen: "Name this bird")
        #expect(labels.contains("Name this bird"), "\(labels)")
        #expect(labels.contains("Name it later"), "closing keeps the photo (issue #188): \(labels)")
        #expect(labels.contains("Delete photo"), "\(labels)")
        #expect(!labels.contains("Cancel"), "\(labels)")
        #expect(labels.contains("Search birds by name"), "the search field's prompt: \(labels)")
        #expect(labels.contains { $0.hasPrefix("Your photo, Today, ") && $0.hasSuffix(", Place not recorded") }, "\(labels)")
        #expect(labels.contains("In your field guides"), "\(labels)")
        // No run, so no place: every add here would be Uncharted.
        #expect(labels.contains("Allen's Hummingbird, Uncharted, New to you here"), "\(labels)")
        #expect(!labels.contains("All birds"), "the rest are found by typing: \(labels)")
        #expect(labels.contains(NameBirdText.searchHint), "\(labels)")
        #expect(labels.contains("Add sighting"), "\(labels)")
        #expect(labels.contains("Choose the bird in your photo."), "\(labels)")
    }

    @Test("A search lists the field guides' birds, then all other birds as Uncharted; one nothing matches says so and offers to clear", arguments: Screens.sizes)
    func nameThisBirdSearch(typeSize: DynamicTypeSize) async throws {
        let harness = try Screens.Harness()
        defer { UserDefaults.standard.removeObject(forKey: "autoQuery") }

        UserDefaults.standard.set("hummingbird", forKey: "autoQuery")
        let found = try await Screens.walk(NameBirdView(unnamed: try #require(harness.run.capture(Self.photo()))) {}, harness: harness, typeSize: typeSize, inStack: false) { labels in
            labels.contains("All birds")
        }
        Screens.expectClean(found, screen: "Name this bird, searched")
        #expect(found.contains("In your field guides") && found.contains("All birds"), "\(found)")
        #expect(found.contains("Allen's Hummingbird, Uncharted, New to you here"), "\(found)")
        #expect(found.contains("Anna's Hummingbird, Uncharted, Seen once here"), "the seeds have one, with no place: \(found)")
        #expect(found.contains("Amazilia Hummingbird, Uncharted"), "a bird no field guide here describes: \(found)")
        let guides = try #require(found.firstIndex(of: "In your field guides"))
        let all = try #require(found.firstIndex(of: "All birds"))
        #expect(guides < all, "field guides first: \(found)")
        #expect(found.contains { $0.hasPrefix("And ") && $0.hasSuffix(" more. Keep typing to narrow them down.") }, "\(found)")
        #expect(!found.contains(NameBirdText.searchHint), "the hint goes once something is typed: \(found)")

        UserDefaults.standard.set("zzzz", forKey: "autoQuery")
        let none = try await Screens.walk(NameBirdView(unnamed: try #require(harness.run.capture(Self.photo()))) {}, harness: harness, typeSize: typeSize, inStack: false) { labels in
            labels.contains("Clear search")
        }
        Screens.expectClean(none, screen: "Name this bird, no match")
        #expect(none.contains("No birds match “zzzz”"), "\(none)")
        #expect(none.contains("Search by a bird's common or scientific name."), "\(none)")
        #expect(none.contains("Clear search"), "\(none)")
        #expect(!none.contains("In your field guides") && !none.contains("All birds"), "\(none)")
    }

    @Test("A sighting you named: your photo first, how without a microphone, no Heard to choose, and no score with Identification open", arguments: Screens.sizes)
    func namedSighting(typeSize: DynamicTypeSize) async throws {
        let harness = try Screens.Harness()
        let addition = try #require(harness.run.addSeen(Self.allens, photo: Self.photo()))
        harness.run.dismissReveal()
        defer { UserDefaults.standard.removeObject(forKey: "autoDisclosuresOpen") }
        UserDefaults.standard.set(true, forKey: "autoDisclosuresOpen")

        let labels = try await Screens.walk(SightingDetailView(id: addition.sightingID), harness: harness, typeSize: typeSize) { labels in
            labels.contains("Identification") && labels.contains { $0.hasPrefix("You named this bird") }
        }
        Screens.expectClean(labels, screen: "Named sighting")
        Self.expectNoScore(labels.filter { !$0.contains("there is no match score") }, screen: "Named sighting")
        #expect(labels.contains("Your photo"), "the page leads with it: \(labels)")
        #expect(labels.contains { $0.hasPrefix("How") && $0.contains("Seen, photographed with iPhone") }, "\(labels)")
        #expect(labels.contains("You saw this bird and named it from your photo."), "\(labels)")
        #expect(!labels.contains("Heard") && !labels.contains("How you met it"), "no Heard or Seen to choose: \(labels)")
        #expect(labels.contains("You named this bird from your photo. BirdNET did not hear it, so there is no match score."), "\(labels)")
        #expect(!labels.contains { $0.contains("Model score") }, "\(labels)")
        #expect(labels.contains { $0.contains("Photo attached") }, "\(labels)")
    }

    @Test("A paper card lists a sighting you named as Seen, with no score", arguments: Screens.sizes)
    func paperCardOfANamedSighting(typeSize: DynamicTypeSize) async throws {
        let harness = try Screens.Harness()
        let addition = try #require(harness.run.addSeen(Self.allens, photo: Self.photo()))
        harness.run.dismissReveal()
        let key = CardCollection.Patch.Key(speciesID: Self.allens.speciesID, setID: addition.placement.setID)

        let labels = try await Screens.walk(PatchDetailView(key: key, startsTurned: true), harness: harness, typeSize: typeSize) { labels in
            labels.contains("Turn back") && labels.contains { $0.hasPrefix("1 sighting") }
        }
        Screens.expectClean(labels, screen: "Paper card of a named sighting")
        Self.expectNoScore(labels, screen: "Paper card of a named sighting")
        #expect(labels.contains { $0.hasSuffix(", Seen, Place not recorded") }, "its line in the history: \(labels)")
    }
}
