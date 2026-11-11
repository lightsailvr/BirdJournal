import Album
import Foundation
import Identification
import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import BirdJournal

// Issue #191 (of #185): "Capture a sighting" on the idle Listen tab, on the screens as VoiceOver finds them and presses
// them: the button under Start listening, the camera with nothing said of a run, and "Name this bird" with the phone's
// place or without one. Location, the camera, the Photos library and the geomodel are stand-ins.
@Suite("Capture a sighting when not listening: the screens", .serialized)
@MainActor
struct CaptureWhenIdleScreenTests {
    typealias Screens = ScreenAccessibilityTests
    typealias Controls = CameraControlsTests
    typealias Hosted = LibraryCaptureScreenTests

    static let griffith = CaptureWhenIdleTests.griffith
    static let griffithPlace = CaptureWhenIdleTests.griffithPlace

    @Test("The idle Listen tab: Capture a sighting under Start listening and above the local set, a finger's height, narrower than Start, and it opens the camera with no run", arguments: Screens.sizes)
    func theIdleTab(typeSize: DynamicTypeSize) async throws {
        let harness = try Screens.Harness(location: [Self.griffith])
        defer { harness.run.isCapturing = false }

        try await Hosted.onScreen(NavigationStack { ListenView() }, harness: harness, photos: StandInPhotosLibrary(access: .allowed), libraryPhoto: nil, typeSize: typeSize) { elements in
            let found = try await Controls.settled(elements) { Controls.element("Capture a sighting", in: $0) != nil && Controls.labels($0).contains { $0.hasPrefix("Your local set") } }
            let labels = Controls.labels(found)
            Screens.expectClean(labels, screen: "Listen, idle")
            Screens.expectOneWordPerThing(labels, screen: "Listen, idle")
            let start = try #require(labels.firstIndex(of: "Start listening"), "\(labels)")
            let capture = try #require(labels.firstIndex(of: "Capture a sighting"), "\(labels)")
            let local = try #require(labels.firstIndex(of: "Your local set, Los Angeles"), "\(labels)")
            #expect(start < capture && capture < local, "Start first, then the capture, then the set: \(labels)")
            #expect(labels.count { $0 == "Capture a sighting" } == 1, "\(labels)")

            let button = found[capture]
            #expect(button.accessibilityTraits.contains(.button))
            #expect(!button.accessibilityTraits.contains(.notEnabled))
            #expect(button.accessibilityHint == "Opens the camera. You don't need to be listening.")
            let frame = button.accessibilityFrame, startFrame = found[start].accessibilityFrame
            #expect(frame.height > 43.9, "a finger's height: \(frame)")
            #expect(frame.minY >= startFrame.maxY + 8, "clear of Start listening: \(frame) under \(startFrame)")
            if typeSize == .large {
                #expect(frame.width < startFrame.width - 60, "Start stays the wide one: \(frame) under \(startFrame)")
                #expect(abs(frame.midX - startFrame.midX) < 1, "centred under it: \(frame) under \(startFrame)")
                #expect(frame.maxY < 700, "on the first screen, above the tab bar: \(frame)")
            }

            #expect(button.accessibilityActivate())
            #expect(harness.run.isCapturing && harness.run.isCapturingOutsideRun)
            #expect(harness.run.state == .idle, "no run was started for it")
        }
    }

    @Test("With no run the camera says nothing of listening; its photo is named with the phone's place under it and what is likely there, with no Heard this run; and the add shows its new patch")
    func cameraAndNaming() async throws {
        let harness = try Screens.Harness(location: [Self.griffith])
        defer { harness.run.isCapturing = false }
        // Birds the run would have heard, were there one: nothing of theirs may reach the sheet.
        harness.run.fakeStack = CandidateStack(candidates: [Candidate(species: Species(index: 0, scientificName: "Haemorhous mexicanus", commonName: "House Finch", taxonomicClass: "Aves"), score: 0.8, windowsAboveThreshold: 2, firstHeardAt: 0, lastHeardAt: 1, admittedAt: 1)])
        harness.run.isCapturing = true
        let geomodel = ScriptedOccurrence(["Selasphorus sasin": 0.75])

        try await Hosted.onScreen(CaptureSightingView(), harness: harness, photos: StandInPhotosLibrary(access: .allowed), libraryPhoto: nil, geomodel: geomodel) { elements in
            let camera = try await Controls.settled(elements) { Controls.element("Take photo", in: $0)?.accessibilityTraits.contains(.notEnabled) == false && harness.run.capturePlace != nil }
            let onCamera = Controls.labels(camera)
            Screens.expectClean(onCamera, screen: "Camera, no run")
            #expect(onCamera.contains("Close camera") && onCamera.contains("Choose from library"), "\(onCamera)")
            #expect(!onCamera.contains { $0.localizedCaseInsensitiveContains("listening") }, "no run, nothing said of one: \(onCamera)")
            #expect(try #require(Controls.element("Take photo", in: camera)).accessibilityActivate())

            let naming = try await Controls.settled(elements) { Controls.labels($0).contains("Likely here now") && Controls.labels($0).contains { $0.hasPrefix("Allen's Hummingbird, ") } }
            let labels = Controls.labels(naming)
            Screens.expectClean(labels, screen: "Name this bird, no run")
            let header = try #require(labels.first { $0.hasPrefix("Your photo, Today, ") }, "\(labels)")
            #expect(header.contains(", Near "), "the phone's place: \(header)")
            #expect(!labels.contains(NameBirdText.heardTitle), "no run, no Heard this run: \(labels)")
            #expect(!labels.contains { $0.hasPrefix("House Finch") }, "\(labels)")
            #expect(labels.contains("Likely here now"), "\(labels)")
            #expect(labels.contains("Allen's Hummingbird, Los Angeles, New to you here"), "placed where the phone is: \(labels)")
            let asked = try #require(geomodel.asked.first, "the geomodel was not read")
            #expect((asked.latitude * 10_000).rounded() == 341_365 && (asked.longitude * 10_000).rounded() == -1_182_942, "\(asked)")

            let capture = try #require(Hosted.captures(harness).first)
            #expect(capture.location == Self.griffithPlace)
            #expect(harness.run.sightings.unnamed.isEmpty && !harness.run.showsRun, "no run's photo")

            let row = try #require(Controls.element("Allen's Hummingbird, Los Angeles, New to you here", in: naming))
            #expect(row.accessibilityActivate())
            let chosen = try await Controls.settled(elements) { Controls.element("Add and sew patch", in: $0)?.accessibilityTraits.contains(.notEnabled) == false }
            #expect(try #require(Controls.element("Add and sew patch", in: chosen), "\(Controls.labels(chosen))").accessibilityActivate())

            let sighting = try #require(harness.newest)
            #expect(sighting.scientificName == "Selasphorus sasin" && sighting.method == .seen && sighting.namedByBirder)
            #expect(sighting.location == Self.griffithPlace)
            #expect(harness.run.reveal?.commonName == "Allen's Hummingbird", "its new patch's page")
            #expect(harness.run.acknowledgment?.undo != nil, "and Undo")
            #expect(harness.run.sightings.seen.isEmpty && !harness.run.showsRun)
        }
    }

    @Test("With location refused the naming says the place is not recorded, and every bird's patch would be Uncharted")
    func placeNotRecorded() async throws {
        let harness = try Screens.Harness(location: [.denied])
        defer { harness.run.isCapturing = false }
        harness.run.isCapturing = true

        try await Hosted.onScreen(CaptureSightingView(), harness: harness, photos: StandInPhotosLibrary(access: .allowed), libraryPhoto: nil) { elements in
            let camera = try await Controls.settled(elements) { Controls.element("Take photo", in: $0)?.accessibilityTraits.contains(.notEnabled) == false && harness.run.placeOutsideRun.state == .settled(.denied) }
            #expect(try #require(Controls.element("Take photo", in: camera)).accessibilityActivate())

            let naming = try await Controls.settled(elements) { Controls.labels($0).contains("In your field guides") && Controls.labels($0).contains { $0.hasPrefix("Allen's Hummingbird, ") } }
            let labels = Controls.labels(naming)
            Screens.expectClean(labels, screen: "Name this bird, no place")
            #expect(labels.contains { $0.hasPrefix("Your photo, Today, ") && $0.hasSuffix(", Place not recorded") }, "\(labels)")
            #expect(labels.contains("Allen's Hummingbird, Uncharted, New to you here"), "\(labels)")
            #expect(!labels.contains("Likely here now") && !labels.contains(NameBirdText.heardTitle), "\(labels)")
            #expect(try #require(Hosted.captures(harness).first).location == nil)
        }
    }

    @Test("A photo taken before the fix shows its place in the naming as soon as the fix is in")
    func thePlaceArrivesInTheNaming() async throws {
        let harness = try Screens.Harness()
        let location = HeldLocationProvider()
        let run = ListeningCoordinator(
            phone: harness.run.phone, glasses: harness.run.glasses, sightings: harness.run.sightings, levels: LevelSink(), defaultSource: .phone,
            defaults: UserDefaults(suiteName: "idle-screen-\(UUID().uuidString)")!, captureLocation: location
        )
        defer { run.isCapturing = false }
        run.isCapturing = true
        let geomodel = ScriptedOccurrence(["Selasphorus sasin": 0.75])

        try await Hosted.onScreen(CaptureSightingView().environment(run), harness: harness, photos: StandInPhotosLibrary(access: .allowed), libraryPhoto: nil, geomodel: geomodel) { elements in
            let camera = try await Controls.settled(elements) { Controls.element("Take photo", in: $0)?.accessibilityTraits.contains(.notEnabled) == false }
            #expect(try #require(Controls.element("Take photo", in: camera)).accessibilityActivate())
            let before = try await Controls.settled(elements) { Controls.labels($0).contains { $0.hasPrefix("Allen's Hummingbird, ") } }
            #expect(Controls.labels(before).contains { $0.hasSuffix(", Place not recorded") }, "nothing known yet: \(Controls.labels(before))")
            #expect(Controls.labels(before).contains("Allen's Hummingbird, Uncharted, New to you here"), "\(Controls.labels(before))")

            location.send(Self.griffith)

            let after = try await Controls.settled(elements) { Controls.labels($0).contains("Likely here now") && Controls.labels($0).contains("Allen's Hummingbird, Los Angeles, New to you here") }
            let labels = Controls.labels(after)
            #expect(labels.contains { $0.hasPrefix("Your photo, Today, ") && $0.contains(", Near ") }, "\(labels)")
            #expect(!labels.contains { $0.hasSuffix(", Place not recorded") }, "\(labels)")
            #expect(labels.contains("Allen's Hummingbird, Los Angeles, New to you here"), "\(labels)")
            #expect(labels.contains("Likely here now"), "what is likely there, now that there is a there: \(labels)")
            #expect(try #require(Hosted.captures(harness).first).location == Self.griffithPlace)
        }
    }

    @Test("With no camera to give and no run, the camera points to the library and says nothing of a run; nor does one opened after a run that left nothing", arguments: Screens.sizes)
    func noCameraAndNoRun(typeSize: DynamicTypeSize) async throws {
        let harness = try Screens.Harness()
        defer { harness.run.isCapturing = false }
        harness.run.isCapturing = true
        let none = try await Screens.walk(CaptureCameraView(camera: StandInCaptureCamera(.unavailable), taken: { _ in }, close: {}), harness: harness, typeSize: typeSize, inStack: false) { labels in
            labels.contains("No camera to use")
        }
        Screens.expectClean(none, screen: "No camera, no run")
        #expect(none.contains("This iPhone's camera can't be opened right now. You can still choose a photo from your library."), "\(none)")
        #expect(none.contains("Choose from library"), "\(none)")
        #expect(!none.contains { $0.localizedCaseInsensitiveContains("run") || $0.localizedCaseInsensitiveContains("listening") }, "\(none)")
        harness.run.isCapturing = false

        // A run that heard nothing has ended: the tab is idle again, and so is its camera.
        await harness.run.start()
        await harness.run.stop()
        #expect(harness.run.state == .ended(.stopped) && !harness.run.showsRun)
        harness.run.isCapturing = true
        let after = try await Screens.walk(CaptureCameraView(camera: StandInCaptureCamera(.ready), taken: { _ in }, close: {}), harness: harness, typeSize: typeSize, inStack: false) { labels in
            labels.contains("Take photo") && labels.contains("Viewfinder")
        }
        #expect(!after.contains { $0.localizedCaseInsensitiveContains("listening") }, "\(after)")
    }

    @Test("On a run the camera with none to give still says the run keeps listening")
    func noCameraOnARun() async throws {
        let harness = try Screens.Harness()
        await harness.run.start()
        harness.run.isCapturing = true
        let labels = try await Screens.walk(CaptureCameraView(camera: StandInCaptureCamera(.unavailable), taken: { _ in }, close: {}), harness: harness, inStack: false) { labels in
            labels.contains("No camera to use")
        }
        harness.run.isCapturing = false
        await harness.run.stop()
        #expect(labels.contains("This iPhone's camera can't be opened right now. A run keeps listening without it."), "\(labels)")
    }
}
