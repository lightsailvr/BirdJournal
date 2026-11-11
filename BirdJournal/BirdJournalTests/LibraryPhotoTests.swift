import Album
import Foundation
import Identification
import ImageIO
import SwiftData
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import BirdJournal

// Issue #192 (of #185): a photo chosen from the library, taken earlier or with a real camera. It is kept as it came, and its
// sighting takes the date and the place the picture itself carries; what it doesn't carry is the current one.
@Suite("Library photos")
@MainActor
struct LibraryPhotoTests {
    /// A small JPEG carrying the EXIF and GPS tags given, written by ImageIO as a camera's file would carry them.
    nonisolated static func picture(exif: [CFString: Any] = [:], gps: [CFString: Any] = [:]) -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { renderer in
            UIColor.brown.setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        let data = NSMutableData()
        guard let cgImage = image.cgImage, let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return Data() }
        var properties: [CFString: Any] = [:]
        if !exif.isEmpty { properties[kCGImagePropertyExifDictionary] = exif }
        if !gps.isEmpty { properties[kCGImagePropertyGPSDictionary] = gps }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// Portal, Arizona, as a camera writes it: unsigned numbers with their hemispheres.
    static var portalGPS: [CFString: Any] {
        [
            kCGImagePropertyGPSLatitude: 31.9137, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 109.1412, kCGImagePropertyGPSLongitudeRef: "W",
        ]
    }
    nonisolated static let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
    nonisolated static let now = Date(timeIntervalSince1970: 1_800_000_000)  // 15 January 2027
    nonisolated static func instant(_ iso: String) throws -> Date { try Date(iso, strategy: .iso8601) }

    @Test("a picture's own date is read with the offset it was written with, and its place with its hemispheres")
    func factsOfAPhonePhoto() throws {
        let data = Self.picture(
            exif: [kCGImagePropertyExifDateTimeOriginal: "2026:04:18 06:42:10", kCGImagePropertyExifOffsetTimeOriginal: "-07:00"],
            gps: Self.portalGPS.merging([kCGImagePropertyGPSHPositioningError: 6.5]) { $1 }
        )

        let facts = try #require(PhotoFacts(of: data, timeZone: Self.losAngeles))

        #expect(facts.takenAt == (try Self.instant("2026-04-18T13:42:10Z")), "Arizona's 06:42, wherever the phone is now")
        let place = try #require(facts.place)
        #expect(abs(place.latitude - 31.9137) < 0.000_01)
        #expect(abs(place.longitude - -109.1412) < 0.000_01, "west is negative")
        #expect(place.accuracy == 6.5)
    }

    @Test("south and east are read too, and a date written without an offset is read on the phone's clock")
    func factsOfACameraPhoto() throws {
        let data = Self.picture(
            exif: [kCGImagePropertyExifDateTimeOriginal: "2026:11:02 09:05:00"],
            gps: [
                kCGImagePropertyGPSLatitude: 33.8568, kCGImagePropertyGPSLatitudeRef: "S",
                kCGImagePropertyGPSLongitude: 151.2153, kCGImagePropertyGPSLongitudeRef: "E",
            ]
        )

        let facts = try #require(PhotoFacts(of: data, timeZone: Self.losAngeles))

        #expect(facts.takenAt == (try Self.instant("2026-11-02T17:05:00Z")), "09:05 Pacific Standard Time")
        #expect(facts.place.map { ($0.latitude * 10_000).rounded() } == -338_568)
        #expect(facts.place.map { ($0.longitude * 10_000).rounded() } == 1_512_153)
        #expect(facts.place?.accuracy == 0, "the file doesn't say how good the fix was")
    }

    @Test("a picture that carries neither says so, a camera's unset clock and a missing fix are not a date and a place, and bytes that are no picture have no facts")
    func nothingToRead() throws {
        let bare = try #require(PhotoFacts(of: DebugSeeds.frameJPEG(), timeZone: Self.losAngeles))
        #expect(bare.takenAt == nil)
        #expect(bare.place == nil)

        let unset = Self.picture(
            exif: [kCGImagePropertyExifDateTimeOriginal: "0000:00:00 00:00:00"],
            gps: [kCGImagePropertyGPSLatitude: 0.0, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 0.0, kCGImagePropertyGPSLongitudeRef: "E"]
        )
        let facts = try #require(PhotoFacts(of: unset, timeZone: Self.losAngeles))
        #expect(facts.takenAt == nil)
        #expect(facts.place == nil)

        #expect(PhotoFacts(of: Data([1, 2, 3]), timeZone: Self.losAngeles) == nil)
        #expect(PhotoFacts(of: Data(), timeZone: Self.losAngeles) == nil)
    }

    // MARK: - Chosen from the library

    @Test("a photo chosen from the library is kept as it came and takes its own date and place")
    func chosenWithItsOwnDateAndPlace() throws {
        let data = Self.picture(
            exif: [kCGImagePropertyExifDateTimeOriginal: "2026:04:18 06:42:10", kCGImagePropertyExifOffsetTimeOriginal: "-07:00"],
            gps: Self.portalGPS
        )

        let photo = try #require(CapturedPhoto.chosenFromLibrary(data, now: Self.now, timeZone: Self.losAngeles))

        #expect(photo.data == data, "not a byte changed")
        #expect(photo.takenAt == (try Self.instant("2026-04-18T13:42:10Z")))
        #expect(photo.place.map { ($0.latitude * 10_000).rounded() } == 319_137)
        #expect(photo.origin == .library(carriesDate: true))
    }

    @Test("a chosen photo with no date takes the time now and no place of its own, a date still to come is not believed, and what is no picture is not chosen")
    func chosenWithout() throws {
        let bare = try #require(CapturedPhoto.chosenFromLibrary(DebugSeeds.frameJPEG(), now: Self.now, timeZone: Self.losAngeles))
        #expect(bare.takenAt == Self.now)
        #expect(bare.place == nil, "the sighting takes the current place")
        #expect(bare.origin == .library(carriesDate: false))

        // A camera whose clock is a year ahead.
        let ahead = Self.picture(exif: [kCGImagePropertyExifDateTimeOriginal: "2028:01:15 08:00:00", kCGImagePropertyExifOffsetTimeOriginal: "-08:00"], gps: Self.portalGPS)
        let photo = try #require(CapturedPhoto.chosenFromLibrary(ahead, now: Self.now, timeZone: Self.losAngeles))
        #expect(photo.takenAt == Self.now)
        #expect(photo.origin == .library(carriesDate: false))
        #expect(photo.place != nil, "its place is still its own")

        #expect(CapturedPhoto.chosenFromLibrary(Data([1, 2, 3]), now: Self.now, timeZone: Self.losAngeles) == nil)
    }

    @Test("the capture camera's photo has no place of its own and says it is the camera's")
    func theCamerasPhoto() async throws {
        let camera = StandInCaptureCamera(.ready)
        await camera.start()
        let photo = try await camera.takePhoto()
        #expect(photo.place == nil)
        #expect(photo.origin == .camera)
    }

    @Test("the naming says whether a library photo's date and place are its own, and what the sighting takes when they aren't; of the camera's photo there is nothing to say")
    func notes() throws {
        let here = Coordinate(latitude: 34.1365, longitude: -118.2942, accuracy: 10)
        let dated = [kCGImagePropertyExifDateTimeOriginal: "2026:04:18 06:42:10", kCGImagePropertyExifOffsetTimeOriginal: "-07:00"] as [CFString: Any]
        func chosen(exif: [CFString: Any] = [:], gps: [CFString: Any] = [:]) throws -> CapturedPhoto {
            try #require(CapturedPhoto.chosenFromLibrary(Self.picture(exif: exif, gps: gps), now: Self.now, timeZone: Self.losAngeles))
        }

        #expect(LibraryPhotoText.note(for: CapturedPhoto(data: Data([1]), takenAt: Self.now), currentPlace: here) == nil)
        #expect(LibraryPhotoText.note(for: try chosen(exif: dated, gps: Self.portalGPS), currentPlace: here) == "The sighting takes this photo's own date and place.")
        #expect(LibraryPhotoText.note(for: try chosen(exif: dated, gps: Self.portalGPS), currentPlace: nil) == "The sighting takes this photo's own date and place.")
        #expect(LibraryPhotoText.note(for: try chosen(exif: dated), currentPlace: here) == "This photo carries no place, so the sighting takes its date and the place you're at now.")
        #expect(LibraryPhotoText.note(for: try chosen(exif: dated), currentPlace: nil) == "This photo carries no place, so the sighting takes its date and records no place.")
        #expect(LibraryPhotoText.note(for: try chosen(gps: Self.portalGPS), currentPlace: here) == "This photo carries no date, so the sighting takes its place and the time now.")
        #expect(LibraryPhotoText.note(for: try chosen(), currentPlace: here) == "This photo carries no date or place, so the sighting takes the time and place now.")
        #expect(LibraryPhotoText.note(for: try chosen(), currentPlace: nil) == "This photo carries no date or place, so the sighting takes the time now and records no place.")
    }

    @Test("the picture that stands in for the library's in a UI test carries what it says it does: a date and a place of its own, in San Diego")
    func theStandInPicture() throws {
        let photo = try #require(CapturedPhoto.chosenFromLibrary(DebugSeeds.libraryPhotoJPEG(), now: Self.now, timeZone: Self.losAngeles))
        #expect(photo.takenAt == (try Self.instant("2026-04-18T13:42:10Z")))
        #expect(photo.place.map { ($0.latitude * 10_000).rounded() } == 327_157)
        #expect(photo.place.map { ($0.longitude * 10_000).rounded() } == -1_171_611)
    }

    // MARK: - On a run

    @Test("on a run a photo chosen from the library is written with its own date and place, not the run's, and named there: the sighting has them, and its rarity is read for that place and week")
    func chosenOnARun() async throws {
        let harness = try ListeningCoordinatorTests.makeHarness()
        let run = harness.run
        await run.start()
        try await waitUntil("the run has its place") { run.coordinate != nil }
        let taken = try Self.instant("2026-04-18T13:42:10Z")
        let data = Self.picture(
            exif: [kCGImagePropertyExifDateTimeOriginal: "2026:04:18 06:42:10", kCGImagePropertyExifOffsetTimeOriginal: "-07:00"],
            gps: Self.portalGPS
        )
        let photo = try #require(CapturedPhoto.chosenFromLibrary(data, now: taken.addingTimeInterval(86_400 * 30), timeZone: Self.losAngeles))
        let portal = try #require(photo.place)

        let unnamed = try #require(run.capture(photo))

        #expect(unnamed.takenAt == taken)
        #expect(unnamed.location == portal, "Arizona, not the run's New York: \(String(describing: unnamed.location))")
        #expect(unnamed.source == .phone)
        #expect(try Data(contentsOf: harness.frames.appending(path: unnamed.photoPath)) == data, "copied into the app unchanged")
        // Review of #185, c5: taken last April, it is not this run's photo.
        #expect(run.sightings.unnamed.isEmpty, "not under Seen this run: it was taken on another day")
        #expect(run.heardScientificNames(for: unnamed).isEmpty, "and offered nothing this run heard")

        try #require(run.name(unnamed, as: SeenSightingTests.finch))
        #expect(run.sightings.seen.isEmpty && run.sightings.identifiers.isEmpty, "named, it is on no run's list and in no recap")
        let sighting = try #require(harness.stored.first)
        #expect(sighting.confirmedAt == taken)
        #expect(sighting.location == portal)
        #expect(sighting.method == .seen && sighting.namedByBirder)
        #expect(harness.rarityPrior.asked == [GeoContext(latitude: portal.latitude, longitude: portal.longitude, week: GeoContext.week(of: taken))], "for the date and place it records")
        #expect(sighting.rarity?.week == GeoContext.week(of: taken))
        run.dismissReveal()

        // One that carries neither: the time it was chosen, and the place the run has.
        let chosenAt = Date(timeIntervalSince1970: 1_790_000_000)
        let bare = try #require(CapturedPhoto.chosenFromLibrary(DebugSeeds.frameJPEG(), now: chosenAt, timeZone: Self.losAngeles))
        let here = try #require(run.capture(bare))
        #expect(here.takenAt == chosenAt)
        #expect(here.location == run.coordinate)
        #expect(run.sightings.unnamed.map(\.id) == [here.id], "with no date of its own it is the run's, as the shutter's is")

        // One that carries a date within the run: a picture from this walk, taken with another camera.
        let during = try #require(run.startedAt).addingTimeInterval(0.001)
        let fromThisWalk = try #require(run.capture(CapturedPhoto(data: DebugSeeds.frameJPEG(), takenAt: during, origin: .library(carriesDate: true))))
        #expect(run.sightings.unnamed.map(\.id) == [here.id, fromThisWalk.id], "the run's own")
        // And one from a minute before the run started.
        let before = try #require(run.capture(CapturedPhoto(data: DebugSeeds.frameJPEG(), takenAt: during.addingTimeInterval(-61), origin: .library(carriesDate: true))))
        #expect(!run.sightings.unnamed.contains(before), "not this run's")
        #expect((try? harness.album.mainContext.fetchCount(FetchDescriptor<Capture>())) == 3, "each is in the album to name")

        await run.stop()
    }

    private func waitUntil(_ what: String, timeout: Duration = .seconds(30), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out waiting until \(what)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
