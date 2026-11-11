import Album
import Foundation
import Pack
import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import BirdJournal

// Issue #190 (of #185): "Change bird" as VoiceOver reaches it, in the serialized suite that walks the capture's other
// screens (they share a window and `-autoQuery`): the button on the page of a sighting the birder named, and not on one
// BirdNET heard; the naming sheet opened on a sighting; and the change made with the sheet's own controls.
extension CaptureAccessibilityTests {
    /// A run in Griffith Park on which the birder saw and named an Allen's Hummingbird, new to them in Los Angeles. The
    /// seeds hold an Anna's Hummingbird heard with no place, and a House Finch heard twice in Los Angeles.
    static func runThatNamedAnAllens() async throws -> (harness: Screens.Harness, sighting: Sighting) {
        let harness = try Screens.Harness(location: [griffithPark])
        await harness.run.start()
        #expect(harness.run.coordinate != nil)
        let addition = try #require(harness.run.addSeen(allens, photo: photo()))
        harness.run.finishCeremony()
        harness.run.dismissReveal()
        let sighting = try #require(try harness.album.mainContext.fetch(Sighting.newestFirst()).first { $0.identifier == addition.identifier })
        return (harness, sighting)
    }

    /// `screen`, which brings its own navigation stack, in a phone-sized window with app accessibility on, for as long as
    /// `body` runs. `elements` walks what VoiceOver reaches at that moment.
    static func onScreen(_ screen: some View, harness: Screens.Harness, _ body: (_ elements: () -> [NSObject]) async throws -> Void) async throws {
        await harness.place.prepareForLaunch()
        CardFlipAccessibilityTests.enableAccessibility()
        let host = UIHostingController(rootView: harness.shared(screen, typeSize: .large))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 2400)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        defer { window.isHidden = true }
        try await body { CameraControlsTests.elements(host.view) }
    }

    @Test("A sighting you named offers Change bird under how it was named; a sighting BirdNET heard does not, even marked Seen", arguments: Screens.sizes)
    func changeBirdIsOnlyOnASightingYouNamed(typeSize: DynamicTypeSize) async throws {
        let (harness, sighting) = try await Self.runThatNamedAnAllens()
        let labels = try await Screens.walk(SightingDetailView(id: sighting.persistentModelID), harness: harness, typeSize: typeSize) { labels in
            labels.contains("Change bird") && labels.contains("Your note")
        }
        Screens.expectClean(labels, screen: "Named sighting")
        Screens.expectOneWordPerThing(labels, screen: "Named sighting")
        let named = try #require(labels.firstIndex(of: "You saw this bird and named it from your photo."), "\(labels)")
        let change = try #require(labels.firstIndex(of: "Change bird"), "\(labels)")
        let note = try #require(labels.firstIndex(of: "Your note"), "\(labels)")
        #expect(named < change && change < note, "under the line that says the name is yours: \(labels)")
        #expect(labels.count { $0 == "Change bird" } == 1, "\(labels)")

        // The seeded Black Phoebe was heard; say it was seen too, as its page lets the birder do.
        let heard = try #require(try harness.album.mainContext.fetch(Sighting.newestFirst()).first { $0.scientificName == "Sayornis nigricans" })
        harness.edits.setMethod(.seen, on: heard)
        let heardLabels = try await Screens.walk(SightingDetailView(id: heard.persistentModelID), harness: harness, typeSize: typeSize) { labels in
            labels.contains("You saw this bird.") && labels.contains("Your note")
        }
        await harness.run.stop()
        #expect(heardLabels.contains("You saw this bird."), "\(heardLabels)")
        #expect(!heardLabels.contains("Change bird"), "BirdNET named it: \(heardLabels)")
        #expect(!heardLabels.contains("You saw this bird and named it from your photo."), "\(heardLabels)")
    }

    @Test("Change bird: the sighting's bird and photo, Cancel where a photo has Name it later and Delete photo, the bird it is marked, and nothing to press until another is chosen", arguments: Screens.sizes)
    func changeBirdSheet(typeSize: DynamicTypeSize) async throws {
        let (harness, sighting) = try await Self.runThatNamedAnAllens()
        defer { UserDefaults.standard.removeObject(forKey: "autoQuery") }
        UserDefaults.standard.set("hummingbird", forKey: "autoQuery")
        let screen = NameBirdView(changing: NamedSighting(sighting, commonName: "Allen's Hummingbird")) { _ in true } close: {}
            .environment(\.occurrenceModel, Self.geomodel)

        let labels = try await Screens.walk(screen, harness: harness, typeSize: typeSize, inStack: false) { labels in
            labels.contains("In your field guides") && labels.contains { $0.hasPrefix("Anna's Hummingbird, ") }
        }
        await harness.run.stop()

        Screens.expectClean(labels, screen: "Change bird")
        Screens.expectOneWordPerThing(labels, screen: "Change bird")
        Self.expectNoScore(labels, screen: "Change bird")
        #expect(labels.count { $0 == "Change bird" } == 2, "the sheet's title and its button: \(labels)")
        #expect(!labels.contains("Name this bird"), "\(labels)")
        #expect(labels.contains("Cancel"), "\(labels)")
        #expect(!labels.contains("Name it later") && !labels.contains("Delete photo"), "a sighting isn't a photo waiting: \(labels)")
        #expect(labels.contains { $0.hasPrefix("Allen's Hummingbird, your photo, Today, ") && $0.contains(", Near ") }, "the sighting: \(labels)")
        #expect(labels.contains("Allen's Hummingbird, Los Angeles, This sighting's bird"), "\(labels)")
        #expect(labels.contains("Anna's Hummingbird, Los Angeles, New to you here"), "the seeds' one has no place: \(labels)")
        #expect(labels.contains("Choose the bird you saw."), "\(labels)")
        #expect(!labels.contains("Add sighting") && !labels.contains("Add and sew patch") && !labels.contains("Choose the bird in your photo."), "\(labels)")
    }

    @Test("Choosing another bird and pressing the button changes the sighting and closes the sheet; before that the note says what the change does to both patches, and nothing is celebrated after")
    func changeBirdWithTheSheet() async throws {
        let (harness, sighting) = try await Self.runThatNamedAnAllens()
        let identifier = sighting.identifier
        defer { UserDefaults.standard.removeObject(forKey: "autoQuery") }
        UserDefaults.standard.set("hummingbird", forKey: "autoQuery")
        final class Closed { var count = 0 }
        let closed = Closed()
        let screen = NameBirdView(changing: NamedSighting(sighting, commonName: "Allen's Hummingbird")) { bird in
            harness.edits.changeBird(of: sighting, to: bird)
        } close: {
            closed.count += 1
        }
        .environment(\.occurrenceModel, Self.geomodel)

        try await Self.onScreen(screen, harness: harness) { elements in
            let listed = try await CameraControlsTests.settled(elements) { found in
                CameraControlsTests.labels(found).contains { $0.hasPrefix("Anna's Hummingbird, ") }
            }
            let button = try #require(listed.last { $0.accessibilityLabel == "Change bird" && $0.accessibilityTraits.contains(.button) }, "\(CameraControlsTests.labels(listed))")
            #expect(button.accessibilityTraits.contains(.notEnabled), "nothing chosen")

            // The bird it already is can be looked at, not chosen as the change.
            let current = try #require(CameraControlsTests.element("Allen's Hummingbird, Los Angeles, This sighting's bird", in: listed), "\(CameraControlsTests.labels(listed))")
            #expect(current.accessibilityActivate())
            let same = try await CameraControlsTests.settled(elements) { CameraControlsTests.labels($0).contains("This sighting is already named Allen's Hummingbird.") }
            #expect(CameraControlsTests.labels(same).contains("This sighting is already named Allen's Hummingbird."), "\(CameraControlsTests.labels(same))")
            let still = try #require(same.last { $0.accessibilityLabel == "Change bird" && $0.accessibilityTraits.contains(.button) })
            #expect(still.accessibilityTraits.contains(.notEnabled))

            let annas = try #require(CameraControlsTests.element("Anna's Hummingbird, Los Angeles, New to you here", in: same), "\(CameraControlsTests.labels(same))")
            #expect(annas.accessibilityActivate())
            let chosen = try await CameraControlsTests.settled(elements) { CameraControlsTests.labels($0).contains("Change and sew patch") }
            #expect(
                CameraControlsTests.labels(chosen).contains("Anna's Hummingbird, new to you here. Your Allen's Hummingbird patch in Los Angeles will be unpicked."),
                "\(CameraControlsTests.labels(chosen))"
            )
            let confirm = try #require(CameraControlsTests.element("Change and sew patch", in: chosen), "\(CameraControlsTests.labels(chosen))")
            #expect(!confirm.accessibilityTraits.contains(.notEnabled))
            #expect(confirm.accessibilityActivate())
            for _ in 0..<50 where closed.count == 0 { try await Task.sleep(for: .milliseconds(100)) }
        }

        #expect(closed.count == 1, "the sheet closes once the change is written")
        #expect(sighting.speciesID == "Calypte anna_Anna's Hummingbird")
        let collection = harness.collectionStore.collection
        let patch = try #require(collection.patch(of: identifier))
        #expect(patch.scientificName == "Calypte anna" && patch.placement.setName == "Los Angeles" && patch.count == 1)
        #expect(collection.patch(scientificName: "Selasphorus sasin", setID: patch.placement.setID) == nil, "the Allen's patch is unpicked")
        #expect(harness.run.reveal == nil && !harness.run.hasCeremonyWaiting, "no stitch-in for the patch the change sewed")
        await harness.run.stop()
        #expect(harness.run.reveal == nil)
    }
}
