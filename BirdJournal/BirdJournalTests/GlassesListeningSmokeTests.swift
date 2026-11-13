import Album
import Foundation
import Identification
import LensSession
import MWDATCore
import MWDATInputs
import MWDATMockDevice
import SwiftData
import Testing
import UIKit
@testable import BirdJournal

// The whole loop on Mock Device Kit (issue #9): one session shared by the stream, Display and Inputs; audio through
// the engine onto the lens; "Add to my list" writes the album. The mock injects neither audio nor video frames
// (DAT-SETUP-CHECKLIST.md), so a test source stands in for the stream and the frame path is checked with its frames;
// the real stream's frames are verified on hardware.
extension MockDeviceKitTests {
    @Suite("Glasses listening run")
    struct GlassesListening {
        @Test("a species heard on the glasses shows on the lens, Add to my list writes it to the album, and the lens names the card it earned")
        func hearConfirmSave() async throws {
            try await withMockDisplay { glasses in
                let connection = GlassesConnection()
                try await waitUntil { connection.connectedDevice != nil }
                let source = ManualAudioSource()
                let album = try AlbumSchema.makeContainer(inMemory: true)
                let run = GlassesListeningSession(
                    recorder: SightingRecorder(container: album, frames: FrameStore(directory: Self.temporaryFrames())),
                    loadEngine: { IdentificationEngine(model: ScriptedBirdModel(), occurrenceModel: SpyOccurrence()) },
                    makeSource: { _ in source },
                    location: ScriptedLocationProvider([ListeningSessionTests.newYork]),
                    profile: FakeLensStack.profile(for:),
                    image: FakeLensStack.image(for:)
                )

                await run.start()
                try #require(run.phase == .listening, "\(run.errorMessage ?? "no error")")
                #expect(run.sessionState == .started)
                #expect(run.lens.page == .list)
                #expect(run.lens.card.elements[0] == .heading("No species yet"))
                try await waitUntil { run.lens.inputsState == .active }

                // Windows at 0 and 1.5 s: finch and jay heard twice, both admitted away from Los Angeles.
                source.feed(seconds: 4.5)
                try await waitUntil { run.lens.stack.count == 2 }
                #expect(run.lens.page == .list)
                #expect(run.lens.card.elements[0] == .heading("2 species heard"))
                #expect(run.listening.list.rows.count == 2)

                let input = glasses.services.input
                let before = Date.now
                try await openSpecies(0, on: run.lens, glasses: glasses)
                #expect(run.lens.card.elements.contains(.title("House Finch", detail: "90% match")))
                input.navDown()
                try await waitUntil(timeout: .seconds(1)) { run.lens.page == .details(index: 0) }
                // "Add to my list" opens the viewfinder; a swipe there adds the bird without a photo.
                input.select()
                try await waitUntil(timeout: .seconds(1)) { run.lens.page == .viewfinder(index: 0) }
                // Opening it makes sure the stream is up (#46).
                try await waitUntil(timeout: .seconds(1)) { source.streamChecks == ["viewfinder"] }
                input.navRight()
                try await waitUntil(timeout: .seconds(2)) { run.saved.count == 1 }
                #expect(run.lens.page == .details(index: 0))
                // The birder's first House Finch with no place: the saved line names its new patch (issues #132, #135).
                try await waitUntil(timeout: .seconds(1)) { run.lens.card.elements.contains(.saved("New patch · sewn")) }
                #expect(run.lens.card.wordCount <= LensCardRenderer.detailsWordBudget)

                let sightings = try album.mainContext.fetch(FetchDescriptor<Sighting>())
                #expect(sightings.count == 1)
                let sighting = try #require(sightings.first)
                #expect(sighting.speciesID == "Haemorhous mexicanus_House Finch")
                #expect(sighting.location == Coordinate(latitude: 40.7, longitude: -74, accuracy: 30))
                #expect(abs(sighting.soundConfidence - 0.9) < 1e-6)
                #expect(sighting.source == .glasses)
                #expect(sighting.frameImagePath == nil, "added without a photo")
                #expect(sighting.confirmedAt >= before && sighting.confirmedAt <= .now)
                #expect(run.saved.first?.hasFrame == false)

                // Adding again opens the viewfinder; a Select right behind the press that opened it (one press the
                // hardware delivered twice) takes no photo; a deliberate one later takes it and adds a second sighting
                // of the same bird.
                input.select()
                try await waitUntil(timeout: .seconds(1)) { run.lens.page == .viewfinder(index: 0) }
                input.select()
                try await waitUntil(timeout: .seconds(1)) { run.lens.inputRecords.count == 6 }
                try await Task.sleep(for: .milliseconds(300))
                #expect(run.lens.savedSightings.count == 1)
                #expect(run.lens.page == .viewfinder(index: 0))
                try await Task.sleep(for: .milliseconds(1100))
                input.select()
                try await waitUntil(timeout: .seconds(1)) { run.lens.savedSightings.count == 2 }
                try await waitUntil(timeout: .seconds(5)) { run.saved.count == 2 }
                #expect(try album.mainContext.fetchCount(FetchDescriptor<Sighting>()) == 2)
                // A New York sighting with no set known: its Uncharted patch, seen again (issues #54, #132).
                try await waitUntil(timeout: .seconds(1)) { run.lens.card.elements.contains(.saved("Seen again · 2 times")) }
                #expect(Set(try album.mainContext.fetch(FetchDescriptor<Sighting>()).map(\.identifier)).count == 2)

                // Back (the middle-finger tap) returns to the list; Back on the root ends the whole run: lens, engine,
                // source and session.
                input.back()
                try await waitUntil(timeout: .seconds(1)) { run.lens.page == .list }
                // Landing on the list makes sure the stream is up too (#46).
                try await waitUntil(timeout: .seconds(1)) { source.streamChecks == ["viewfinder", "viewfinder", "species list"] }
                input.back()
                try await waitUntil(timeout: .seconds(5)) { run.phase == .stopped(.back) }
                #expect(run.lens.phase == .stopped(.back))
                #expect(run.listening.phase == .idle)
                #expect(source.isStopped)
                #expect(run.sessionState == .stopped)
                #expect(run.errorMessage == nil)
            }
        }

        @Test("time with the glasses off isn't time listened: the clock holds still through the pause, and the recap leaves it out")
        func pausedTimeIsNotListened() async throws {
            try await withMockDisplay { glasses in
                let connection = GlassesConnection()
                try await waitUntil { connection.connectedDevice != nil }
                let source = ManualAudioSource()
                let album = try AlbumSchema.makeContainer(inMemory: true)
                let recorder = SightingRecorder(container: album, frames: FrameStore(directory: Self.temporaryFrames()))
                let sightings = RunSightings(recorder: recorder)
                let glassesRun = GlassesListeningSession(
                    recorder: recorder,
                    sightings: sightings,
                    loadEngine: { IdentificationEngine(model: ScriptedBirdModel(), occurrenceModel: SpyOccurrence()) },
                    makeSource: { _ in source },
                    location: ScriptedLocationProvider([ListeningSessionTests.newYork]),
                    profile: FakeLensStack.profile(for:),
                    image: FakeLensStack.image(for:)
                )
                let run = ListeningCoordinator(phone: ListeningSession(), glasses: glassesRun, sightings: sightings, levels: LevelSink(), defaultSource: .glasses, defaults: UserDefaults(suiteName: "lens-ceremony-\(UUID().uuidString)")!)

                await run.start()
                try #require(run.state == .listening, "\(run.errorMessage ?? "no error")")
                try await waitUntil { glassesRun.lens.inputsState == .active }
                source.feed(seconds: 4.5)
                try await waitUntil { glassesRun.lens.stack.count == 2 }

                glasses.powerOff()
                try await waitUntil { run.state == .paused(.disconnected) }
                try await waitUntil(timeout: .seconds(2)) { run.clock.pausedSince != nil }
                #expect(run.snapshot(in: CardCollection([])).pausedAt == run.clock.pausedSince, "the Live Activity's clock holds still too")
                try await Task.sleep(for: .seconds(3))
                glasses.powerOn()
                try await waitUntil(timeout: .seconds(30)) { run.state == .listening }
                try await waitUntil(timeout: .seconds(2)) { run.clock.pausedSince == nil }
                await run.stop()

                let wall = try #require(run.endedAt).timeIntervalSince(try #require(run.startedAt))
                #expect(run.listened <= wall - 3, "listened \(run.listened) of \(wall), paused for at least 3 s")
                #expect(run.listened > 0)
            }
        }

        @Test("a patch sewn on the lens waits for the run to end, and Back on the lens ending it is enough; a repeat from the lens waits for nothing (the maintainer, 2026-11-04)")
        func lensAddWaitsForTheEnd() async throws {
            try await withMockDisplay { glasses in
                let connection = GlassesConnection()
                try await waitUntil { connection.connectedDevice != nil }
                let source = ManualAudioSource()
                let album = try AlbumSchema.makeContainer(inMemory: true)
                let recorder = SightingRecorder(container: album, frames: FrameStore(directory: Self.temporaryFrames()))
                let sightings = RunSightings(recorder: recorder)
                let glassesRun = GlassesListeningSession(
                    recorder: recorder,
                    sightings: sightings,
                    loadEngine: { IdentificationEngine(model: ScriptedBirdModel(), occurrenceModel: SpyOccurrence()) },
                    makeSource: { _ in source },
                    location: ScriptedLocationProvider([ListeningSessionTests.newYork]),
                    profile: FakeLensStack.profile(for:),
                    image: FakeLensStack.image(for:)
                )
                let run = ListeningCoordinator(phone: ListeningSession(), glasses: glassesRun, sightings: sightings, levels: LevelSink(), defaultSource: .glasses, defaults: UserDefaults(suiteName: "lens-ceremony-\(UUID().uuidString)")!)

                await run.start()
                try #require(run.state == .listening, "\(run.errorMessage ?? "no error")")
                try await waitUntil { glassesRun.lens.inputsState == .active }
                source.feed(seconds: 4.5)
                try await waitUntil { glassesRun.lens.stack.count == 2 }

                let input = glasses.services.input
                try await openSpecies(0, on: glassesRun.lens, glasses: glasses)
                input.navDown()
                try await waitUntil(timeout: .seconds(1)) { glassesRun.lens.page == .details(index: 0) }
                input.select()
                try await waitUntil(timeout: .seconds(1)) { glassesRun.lens.page == .viewfinder(index: 0) }
                input.navRight()
                try await waitUntil(timeout: .seconds(2)) { run.sightings.entries.count == 1 }
                try await waitUntil(timeout: .seconds(1)) { glassesRun.lens.card.elements.contains(.saved("New patch · sewn")) }
                #expect(!run.hasCeremonyWaiting)
                #expect(run.reveal == nil, "text on the lens, nothing on the phone")

                input.select()
                try await waitUntil(timeout: .seconds(1)) { glassesRun.lens.page == .viewfinder(index: 0) }
                input.navRight()
                try await waitUntil(timeout: .seconds(2)) { run.sightings.entries.count == 2 }
                try await waitUntil(timeout: .seconds(1)) { glassesRun.lens.card.elements.contains(.saved("Seen again · 2 times")) }

                input.back()
                try await waitUntil(timeout: .seconds(1)) { glassesRun.lens.page == .list }
                input.back()
                try await waitUntil(timeout: .seconds(5)) { run.state == .ended(.endedByGlasses) }
                // Back on the lens is an end like Stop: the recap and its time.
                try await waitUntil(timeout: .seconds(5)) { run.isReviewing }
                #expect(run.endedAt != nil)
                #expect(run.hasCeremonyWaiting)
                run.showNextCeremony()
                #expect(run.reveal?.commonName == "House Finch")
                run.finishCeremony()
                #expect(run.waitingCeremonies == 0, "the repeat added nothing to the queue")
            }
        }

        @Test("a tap on the viewfinder stores the photo it takes, and without one the frame from the moment of the tap, not from when the write finishes")
        func frameFromTapTime() async throws {
            try await withMockDisplay { glasses in
                let connection = GlassesConnection()
                try await waitUntil { connection.connectedDevice != nil }
                let source = ManualAudioSource()
                let album = try AlbumSchema.makeContainer(inMemory: true)
                let frames = FrameStore(directory: Self.temporaryFrames())
                let run = GlassesListeningSession(
                    recorder: SightingRecorder(container: album, frames: frames),
                    loadEngine: { IdentificationEngine(model: ScriptedBirdModel(), occurrenceModel: SpyOccurrence()) },
                    makeSource: { _ in source },
                    location: ScriptedLocationProvider([ListeningSessionTests.newYork]),
                    profile: FakeLensStack.profile(for:),
                    image: FakeLensStack.image(for:)
                )

                await run.start()
                do {
                    try #require(run.phase == .listening, "\(run.errorMessage ?? "no error")")
                    try await waitUntil { run.lens.inputsState == .active }
                    source.feed(seconds: 4.5)
                    try await waitUntil { run.lens.stack.count == 2 }

                    let input = glasses.services.input
                    try await openSpecies(0, on: run.lens, glasses: glasses)
                    input.navDown()
                    try await waitUntil(timeout: .seconds(1)) { run.lens.page == .details(index: 0) }
                    input.select()
                    try await waitUntil(timeout: .seconds(1)) { run.lens.page == .viewfinder(index: 0) }
                    source.latestFrame = Self.frame(.red)
                    #expect(run.hasCameraFrame)
                    try await Task.sleep(for: .milliseconds(1100))
                    // No photo comes from this source, so the frame from the moment of the tap stands in.
                    input.select()
                    try await waitUntil(timeout: .seconds(1)) { run.lens.savedSightings.count == 1 }
                    source.latestFrame = Self.frame(.blue) // The stream moves on while the frame is encoded and written.
                    try await waitUntil(timeout: .seconds(5)) { run.saved.count == 1 }

                    let sighting = try #require(try album.mainContext.fetch(FetchDescriptor<Sighting>()).first)
                    #expect(sighting.speciesID == "Haemorhous mexicanus_House Finch")
                    #expect(run.saved.first?.hasFrame == true)
                    let path = try #require(sighting.frameImagePath)
                    let stored = try #require(UIImage(contentsOfFile: frames.url(for: path).path()), "the stored frame decodes as an image")
                    #expect(Self.dominantChannel(of: stored) == "red", "the frame from the tap is stored, not a later one")

                    // With a photo, the photo is what is stored, over the frame.
                    source.photo = Self.frame(.green).jpegData()
                    input.select()
                    try await waitUntil(timeout: .seconds(1)) { run.lens.page == .viewfinder(index: 0) }
                    try await Task.sleep(for: .milliseconds(1100))
                    input.select()
                    try await waitUntil(timeout: .seconds(1)) { run.lens.savedSightings.count == 2 }
                    try await waitUntil(timeout: .seconds(5)) { run.saved.count == 2 }
                    try await waitUntil(timeout: .seconds(5)) {
                        let path = try? album.mainContext.fetch(Sighting.newestFirst()).first?.frameImagePath
                        return path.flatMap { UIImage(contentsOfFile: frames.url(for: $0).path()) }.map(Self.dominantChannel(of:)) == "green"
                    }
                } catch {
                    await run.stop()
                    throw error
                }
                await run.stop()
                #expect(run.phase == .stopped(.phone))
                #expect(run.sessionState == .stopped)
                #expect(source.isStopped)
            }
        }

        @Test("Capture a sighting on the lens: a swipe up from the first bird reaches the row, and a tap on it takes the photo at once and puts it on the phone as an unnamed sighting of the run, from the glasses, with its time and the run's place, through the run and into its review (issue #193)")
        func captureFromTheLens() async throws {
            try await withMockDisplay { glasses in
                let connection = GlassesConnection()
                try await waitUntil { connection.connectedDevice != nil }
                let source = ManualAudioSource()
                let album = try AlbumSchema.makeContainer(inMemory: true)
                let frames = FrameStore(directory: Self.temporaryFrames())
                let recorder = SightingRecorder(container: album, frames: frames)
                let sightings = RunSightings(recorder: recorder)
                let glassesRun = GlassesListeningSession(
                    recorder: recorder,
                    sightings: sightings,
                    loadEngine: { IdentificationEngine(model: ScriptedBirdModel(), occurrenceModel: SpyOccurrence()) },
                    makeSource: { _ in source },
                    location: ScriptedLocationProvider([ListeningSessionTests.newYork]),
                    profile: FakeLensStack.profile(for:),
                    image: FakeLensStack.image(for:)
                )
                let defaults = try #require(UserDefaults(suiteName: "lens-capture-\(UUID().uuidString)"))
                let run = ListeningCoordinator(phone: ListeningSession(), glasses: glassesRun, sightings: sightings, levels: LevelSink(), defaultSource: .glasses, defaults: defaults)
                let lens = glassesRun.lens
                let captureRow = { lens.card.elements.count > 2 ? lens.card.elements[2] : nil }

                await run.start()
                do {
                    try #require(run.state == .listening, "\(run.errorMessage ?? "no error")")
                    try await waitUntil { lens.inputsState == .active }
                    // No bird yet: the row is the one highlighted.
                    #expect(captureRow() == .capture(label: "Capture a sighting", isSelected: true))
                    source.feed(seconds: 4.5)
                    try await waitUntil { lens.stack.count == 2 }
                    // The first bird takes the highlight, as before; one swipe up reaches the row.
                    #expect(captureRow() == .capture(label: "Capture a sighting", isSelected: false))
                    let input = glasses.services.input
                    input.navUp()
                    try await waitUntil(timeout: .seconds(1)) { captureRow() == .capture(label: "Capture a sighting", isSelected: true) }

                    // A tap on the row is the shutter (2026-11-12): no viewfinder, the photo is taken at once, and the
                    // capture has the camera, so listening stops for it. A tap right behind it is that press delivered
                    // twice: it takes no second photo and does not close "Photo saved" unread.
                    source.latestFrame = Self.frame(.red)
                    source.photo = Self.frame(.green).jpegData()
                    let before = Date.now
                    input.select()
                    input.select()
                    try await waitUntil(timeout: .seconds(5)) { lens.page == .captureSaved }
                    #expect(lens.card.elements == [.heading("Photo saved"), .body("Name it on your phone."), .meta("Tap or swipe right: all species")])
                    try await Task.sleep(for: .milliseconds(400))
                    #expect(lens.page == .captureSaved, "the doubled press closed nothing")

                    // On the phone: an unnamed sighting of this run, which is what "Seen this run" lists, and no sighting.
                    #expect(run.sightings.unnamed.count == 1)
                    let unnamed = try #require(run.sightings.unnamed.first)
                    #expect(unnamed.source == .glasses)
                    #expect(unnamed.location == Coordinate(latitude: 40.7, longitude: -74, accuracy: 30))
                    #expect(unnamed.takenAt >= before && unnamed.takenAt <= .now)
                    let captures = try album.mainContext.fetch(FetchDescriptor<Capture>())
                    #expect(captures.map(\.identifier) == [unnamed.id])
                    #expect(captures.first?.source == .glasses)
                    let stored = try #require(UIImage(contentsOfFile: frames.url(for: unnamed.photoPath).path()), "the stored photo decodes as an image")
                    #expect(Self.dominantChannel(of: stored) == "green", "the photo, not the stream's frame")
                    #expect(try album.mainContext.fetchCount(FetchDescriptor<Sighting>()) == 0, "nothing is added until it is named")
                    #expect(run.sightings.entries.isEmpty)
                    #expect(lens.savedSightings.isEmpty)
                    #expect(run.reveal == nil)
                    #expect(!run.hasCeremonyWaiting)

                    // The capture had the camera while the photo was taken, and nothing asks for a name here: it has
                    // let the camera go, so listening is back.
                    try await waitUntil(timeout: .seconds(1)) { source.captureSteps == [true, false] }

                    // A tap returns to the list with the highlight still on the row (a beat first: a tap right behind
                    // the one that took the photo is taken for it). With no photo from the camera, the frame from the
                    // moment of the tap stands in.
                    try await Task.sleep(for: .milliseconds(1100))
                    input.select()
                    try await waitUntil(timeout: .seconds(1)) { lens.page == .list }
                    try await waitUntil(timeout: .seconds(1)) { source.streamChecks == ["species list"] }
                    #expect(captureRow() == .capture(label: "Capture a sighting", isSelected: true))
                    source.photo = nil
                    input.select()
                    try await waitUntil(timeout: .seconds(1)) { lens.page != .list }
                    source.latestFrame = Self.frame(.blue) // The stream moves on while the frame is encoded and written.
                    try await waitUntil(timeout: .seconds(5)) { lens.page == .captureSaved }
                    #expect(run.sightings.unnamed.count == 2)
                    let second = try #require(run.sightings.unnamed.last)
                    let frame = try #require(UIImage(contentsOfFile: frames.url(for: second.photoPath).path()))
                    #expect(Self.dominantChannel(of: frame) == "red")

                    // With neither a photo nor a frame nothing is saved, and the lens says so.
                    input.navRight()
                    try await waitUntil(timeout: .seconds(1)) { lens.page == .list }
                    source.latestFrame = nil
                    try await Task.sleep(for: .milliseconds(1100))
                    input.select()
                    try await waitUntil(timeout: .seconds(5)) { lens.page == .problem(.photoNotTaken) }
                    #expect(lens.card.elements.first == .heading("No photo taken"))
                    #expect(run.sightings.unnamed.count == 2)
                    input.navRight()
                    try await waitUntil(timeout: .seconds(1)) { lens.page == .list }

                    // A photo given up while it is on its way (2026-11-12): swipe down asks, a tap stops. Nothing is
                    // written, not even the frame from the tap, the lens says nothing more of it, and the camera is
                    // told to stop waiting.
                    source.latestFrame = Self.frame(.red)
                    source.photo = Self.frame(.green).jpegData()
                    source.holdsPhoto = true
                    try await Task.sleep(for: .milliseconds(1100))
                    input.select()
                    try await waitUntil(timeout: .seconds(1)) { lens.page == .captureSaving }
                    #expect(lens.card.elements == [.shutter, .heading("Hold still"), .meta("Taking the photo…")])
                    input.navDown()
                    try await waitUntil(timeout: .seconds(1)) { lens.page == .captureCancel }
                    #expect(lens.card.elements.first == .heading("Stop sending?"))
                    try await Task.sleep(for: .milliseconds(1100))
                    input.select()
                    try await waitUntil(timeout: .seconds(1)) { lens.page == .list }
                    try await waitUntil(timeout: .seconds(1)) { source.cancels == 1 }
                    try await Task.sleep(for: .milliseconds(300))
                    #expect(run.sightings.unnamed.count == 2)
                    #expect(lens.page == .list)

                    // One more, whose photo is still on its way when the run is stopped.
                    source.holdsPhoto = true
                    try await Task.sleep(for: .milliseconds(1100))
                    input.select()
                    try await waitUntil(timeout: .seconds(1)) { lens.page == .captureSaving }
                } catch {
                    source.deliverPhoto()
                    await run.stop()
                    throw error
                }

                // The run ends: its review has the two photos still to name, and is written down with them for a relaunch.
                await run.stop()
                #expect(run.isReviewing)
                #expect(run.sightings.unnamed.count == 2)
                #expect(run.lastRunHasSomething)
                let key = ListeningCoordinator.endedRunKey
                let keptCaptures = { defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(EndedRun.self, from: $0) }?.captures }
                #expect(keptCaptures() == run.sightings.unnamed.map(\.id))
                // The photo that was on its way arrives: it is kept all the same, in the review and in what is written down.
                source.deliverPhoto()
                try await waitUntil(timeout: .seconds(5)) { run.sightings.unnamed.count == 3 }
                #expect(keptCaptures() == run.sightings.unnamed.map(\.id))
                #expect(try album.mainContext.fetchCount(FetchDescriptor<Capture>()) == 3)
                #expect(run.errorMessage == nil)
            }
        }

        /// A solid 64×64 frame, encoded like the stream's frames are.
        private static func frame(_ color: UIColor) -> CameraFrame {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            }
            let data = image.jpegData(compressionQuality: 0.9)
            return CameraFrame { data }
        }

        /// "red", "green" or "blue" by the centre pixel.
        private static func dominantChannel(of image: UIImage) -> String {
            guard let cgImage = image.cgImage else { return "none" }
            var pixel = [UInt8](repeating: 0, count: 4)
            let context = CGContext(
                data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(cgImage, in: CGRect(x: -32, y: -32, width: 64, height: 64))
            let channels = ["red": pixel[0], "green": pixel[1], "blue": pixel[2]]
            return channels.max { $0.value < $1.value }?.key ?? "none"
        }

        private static func temporaryFrames() -> URL {
            URL.temporaryDirectory.appending(path: "frames-\(UUID().uuidString)", directoryHint: .isDirectory)
        }
    }
}
