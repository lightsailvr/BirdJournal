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
                try await waitUntil(timeout: .seconds(1)) { source.viewfinderChanges == [true] }
                input.navRight()
                try await waitUntil(timeout: .seconds(2)) { run.saved.count == 1 }
                #expect(run.lens.page == .details(index: 0))
                try await waitUntil(timeout: .seconds(1)) { source.viewfinderChanges == [true, false] }
                // The birder's first House Finch: the saved line is the Legendary reveal (issue #51).
                try await waitUntil(timeout: .seconds(1)) { run.lens.card.elements.contains(.saved("Your first House Finch", legendary: true)) }
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
                try await waitUntil(timeout: .seconds(1)) { run.lens.card.elements.contains(.saved("New card", legendary: false)) }
                #expect(Set(try album.mainContext.fetch(FetchDescriptor<Sighting>()).map(\.identifier)).count == 2)

                // Back (the middle-finger tap) returns to the list; Back on the root ends the whole run: lens, engine,
                // source and session.
                input.back()
                try await waitUntil(timeout: .seconds(1)) { run.lens.page == .list }
                input.back()
                try await waitUntil(timeout: .seconds(5)) { run.phase == .stopped(.back) }
                #expect(run.lens.phase == .stopped(.back))
                #expect(run.listening.phase == .idle)
                #expect(source.isStopped)
                #expect(run.sessionState == .stopped)
                #expect(run.errorMessage == nil)
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
