import Album
import Foundation
import Pack
import SwiftData
import SwiftUI
import Testing
@testable import BirdJournal

// Issue #188 (of #185): VoiceOver over the places an unnamed sighting waits, walked in process as `ScreenAccessibilityTests`
// walks the rest: under "Seen this run" on the run's page, among the named ones in the order taken; in the Collection's "To
// name"; and with no sighting yet, beside the empty collection. Each at the default text size and the largest.
@Suite("Unnamed sighting accessibility", .serialized)
@MainActor
struct UnnamedSightingAccessibilityTests {
    typealias Screens = ScreenAccessibilityTests

    static let allens = CaptureAccessibilityTests.allens
    static let row = "Unnamed sighting, Your photo, just now, Name it"

    @Test("A run's page: an unnamed sighting is one sentence with Name it, among the seen birds in the order the photos were taken", arguments: Screens.sizes)
    func runPage(typeSize: DynamicTypeSize) async throws {
        let harness = try Screens.Harness()
        await harness.run.start()
        let now = Date.now
        try #require(harness.run.capture(CapturedPhoto(data: DebugSeeds.frameJPEG(), takenAt: now.addingTimeInterval(-30))))
        try #require(harness.run.addSeen(Self.allens, photo: CapturedPhoto(data: DebugSeeds.frameJPEG(), takenAt: now.addingTimeInterval(-20))))
        harness.run.dismissReveal()
        try #require(harness.run.capture(CapturedPhoto(data: DebugSeeds.frameJPEG(), takenAt: now.addingTimeInterval(-10))))

        let labels = try await Screens.walk(ActiveListeningView(), harness: harness, typeSize: typeSize) { labels in
            labels.contains("Seen this run") && labels.filter { $0 == Self.row }.count == 2
        }
        await harness.run.stop()

        Screens.expectClean(labels, screen: "Run with unnamed sightings")
        Screens.expectOneWordPerThing(labels, screen: "Run with unnamed sightings")
        let section = try #require(labels.firstIndex(of: "Seen this run"), "\(labels)")
        let rows = Array(labels[(section + 1)...].prefix(3))
        #expect(rows == [Self.row, "Allen's Hummingbird, Seen, your photo, New patch", Self.row], "in the order taken, named or not: \(labels)")
        #expect(!labels.contains { $0.contains("Unnamed") && $0.contains("New patch") }, "it has earned nothing: \(labels)")
    }

    // The review of #185, a1: a run that heard nothing and took a photo has its review.
    @Test("The review of a run that heard nothing and took a photo: the photo to name under Seen this run, that it is kept, and No birds were heard where the birds would be listed", arguments: Screens.sizes)
    func reviewOfARunOfPhotosAlone(typeSize: DynamicTypeSize) async throws {
        let harness = try Screens.Harness(seeded: false)
        await harness.run.start()
        try #require(harness.run.capture(CapturedPhoto(data: DebugSeeds.frameJPEG(), takenAt: .now)))
        await harness.run.stop()
        try #require(harness.run.candidates.isEmpty && harness.run.isReviewing)

        let labels = try await Screens.walk(RunReviewSheet(), harness: harness, typeSize: typeSize, inStack: false) { labels in
            labels.contains(Self.row) && labels.contains(RunRecap.nothingHeard)
        }

        Screens.expectClean(labels, screen: "Review of a run of photos alone")
        let section = try #require(labels.firstIndex(of: "Seen this run"), "\(labels)")
        let row = try #require(labels.firstIndex(of: Self.row), "\(labels)")
        let heard = try #require(labels.firstIndex(of: "What you heard"), "\(labels)")
        let nothing = try #require(labels.firstIndex(of: "No birds were heard."), "\(labels)")
        #expect(section < row && row < heard && heard < nothing, "the photo, then what was heard: \(labels)")
        #expect(labels.contains(UnnamedSightingText.reviewNote), "the photo is kept: \(labels)")
        #expect(!labels.contains { $0.hasPrefix("Only the birds you add are kept") }, "there is nothing to forget: \(labels)")
    }

    @Test("Collection, Sightings: To name leads the list with each photo waiting, and the totals above count none of them", arguments: Screens.sizes)
    func toName(typeSize: DynamicTypeSize) async throws {
        let harness = try Screens.Harness()
        let sightings = try harness.album.mainContext.fetch(Sighting.newestFirst()).count
        try #require(harness.run.capture(CapturedPhoto(data: DebugSeeds.frameJPEG(), takenAt: .now)))
        try #require(harness.run.capture(CapturedPhoto(data: DebugSeeds.frameJPEG(), takenAt: .now)))
        let state = CollectionState()
        state.mode = .sightings

        let labels = try await Screens.walk(JournalView(state: state), harness: harness, typeSize: typeSize) { labels in
            labels.contains("To name") && labels.filter { $0 == Self.row }.count == 2
        }

        Screens.expectClean(labels, screen: "To name")
        Screens.expectOneWordPerThing(labels, screen: "To name")
        #expect(labels.contains(UnnamedSightingText.toNameNote), "\(labels)")
        #expect(labels.contains { $0.hasSuffix("species, \(sightings) sightings") }, "an unnamed sighting is not counted: \(labels)")
        let heading = try #require(labels.firstIndex(of: "To name"))
        let firstDay = try #require(labels.firstIndex { $0.hasPrefix("Today, ") }, "the seeds' newest day: \(labels)")
        let lastRow = try #require(labels.lastIndex(of: Self.row))
        #expect(heading < lastRow && lastRow < firstDay, "above the days: \(labels)")
    }

    @Test("Collection with no sighting yet: a photo waiting to be named is listed with the way to the first patch", arguments: Screens.sizes)
    func toNameInAnEmptyCollection(typeSize: DynamicTypeSize) async throws {
        let harness = try Screens.Harness(seeded: false)
        try #require(harness.run.capture(CapturedPhoto(data: DebugSeeds.frameJPEG(), takenAt: .now)))

        let labels = try await Screens.walk(JournalView(state: CollectionState()), harness: harness, typeSize: typeSize) { labels in
            labels.contains("To name") && labels.contains(Self.row)
        }

        Screens.expectClean(labels, screen: "To name, empty collection")
        #expect(labels.contains("Your first patch is a bird away."), "\(labels)")
        #expect(labels.contains("Start listening"), "\(labels)")
    }
}
