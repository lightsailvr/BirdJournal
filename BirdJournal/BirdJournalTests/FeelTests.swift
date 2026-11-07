import Album
import Foundation
import Pack
import SwiftUI
import Testing
import UIKit
@testable import BirdJournal

// Issue #150, slice 3: the one table of haptics, the press, what the reveal says about sharing, and decoding ahead. Real taps are in
// `FeelUITests`.
#if DEBUG
@Suite("Feel", .serialized)
@MainActor
struct FeelTests {
    @Test("each haptic means one thing, from the table in the issue")
    func haptics() {
        #expect(Haptic.lift.feedback == .impact(flexibility: .soft))
        #expect(Haptic.turn.feedback == .impact(weight: .light))
        #expect(Haptic.stitchTick.feedback == .selection)
        #expect(Haptic.stitchDone.feedback == .success)
        #expect(Haptic.startStop.feedback == .impact(weight: .medium))
        #expect(Haptic.reaction.feedback == .impact(weight: .light))
        #expect(Haptic.error.feedback == .error)
    }

    @Test("the switch for ticks on a phone-mic run reaches only that run")
    func tickSwitch() {
        #expect(Haptic.ticksDuringPhoneRun, "on, as the issue has it, until a phone says otherwise")
        #expect(Haptic.ticks(phoneRunHoldsSession: true))
        #expect(Haptic.ticks(phoneRunHoldsSession: false))
        #expect(!Haptic.ticks(phoneRunHoldsSession: true, duringPhoneRun: false))
        #expect(Haptic.ticks(phoneRunHoldsSession: false, duringPhoneRun: false), "a glasses run or no run still ticks")
    }

    @Test("a press moves a button, or under Reduce Motion only dims it, and letting go puts it back")
    func press() {
        #expect(PressFeel.appearance(isPressed: true, scale: PressFeel.sinks, reduceMotion: false) == (PressFeel.sinks, 1))
        #expect(PressFeel.appearance(isPressed: true, scale: PressFeel.rises, reduceMotion: false) == (PressFeel.rises, 1))
        #expect(PressFeel.appearance(isPressed: true, scale: PressFeel.sinks, reduceMotion: true) == (1, 0.6))
        #expect(PressFeel.appearance(isPressed: false, scale: PressFeel.sinks, reduceMotion: false) == (1, 1))
        #expect(PressFeel.appearance(isPressed: false, scale: PressFeel.sinks, reduceMotion: true) == (1, 1))
    }

    @Test("Shared with the Guild only when sharing is on, the birder is signed in and is in one")
    func sharedLine() {
        #expect(FindPolicy.sharedLine(sharing: .automatic, signedIn: true, guilds: ["Sunday Group"]) == "Shared with Sunday Group")
        #expect(FindPolicy.sharedLine(sharing: .automatic, signedIn: true, guilds: ["Sunday Group", "Family"]) == "Shared with Sunday Group and Family")
        #expect(FindPolicy.sharedLine(sharing: .automatic, signedIn: true, guilds: ["A", "B", "C"]) == "Shared with your 3 Guilds")
        #expect(FindPolicy.sharedLine(sharing: .automatic, signedIn: true, guilds: []) == nil)
        #expect(FindPolicy.sharedLine(sharing: .automatic, signedIn: false, guilds: ["Sunday Group"]) == nil)
        #expect(FindPolicy.sharedLine(sharing: .private, signedIn: true, guilds: ["Sunday Group"]) == nil)
    }

    /// The bundled pack's first patches, nothing decoded.
    private func arts(_ count: Int) throws -> [PatchArt] {
        let harness = try ScreenAccessibilityTests.Harness(seeded: false)
        PatchTextures.forgetAll()
        let species = try #require(harness.library.pack(id: PackIndex.bundledPackID)).species
        return species.prefix(count).compactMap { harness.library.patchArt(scientificName: $0.scientificName, setID: PackIndex.bundledPackID) }
    }

    @Test("a board decodes ahead, so a patch scrolled to is there on its first frame")
    func decodesAhead() async throws {
        let arts = try arts(6)
        #expect(arts.count == 6)
        #expect(arts.allSatisfy { PatchTextures.cached($0, size: .thumbnail) == nil })
        await PatchTextures.decodeAhead(arts, size: .thumbnail)
        #expect(arts.allSatisfy { PatchTextures.cached($0, size: .thumbnail) != nil })
    }

    @Test("a page opening over its tile starts from the tile's picture, not a blank")
    func pageStartsFromTheTile() async throws {
        let art = try #require(try arts(1).first)
        #expect(PatchTextures.cachedOrSmaller(art, size: .full) == nil)
        let tile = await PatchTextures.load(art, size: .thumbnail)
        #expect(PatchTextures.cachedOrSmaller(art, size: .full) === tile)
        let page = await PatchTextures.load(art, size: .full)
        #expect(PatchTextures.cachedOrSmaller(art, size: .full) === page)
        #expect(PatchTextures.cachedOrSmaller(art, size: .thumbnail) === tile, "and a tile never takes the larger one")
    }

    @Test("leaving a board stops decoding its patches ahead")
    func stopsDecodingAhead() async throws {
        let arts = try arts(30)
        let ahead = Task { await PatchTextures.decodeAhead(arts, size: .thumbnail) }
        ahead.cancel()
        await ahead.value
        #expect(arts.contains { PatchTextures.cached($0, size: .thumbnail) == nil }, "it didn't decode them all anyway")
    }

    @Test("decoding ahead doesn't hold up a patch on screen, which still decodes while the queue is busy")
    func visibleFirst() async throws {
        let arts = try arts(12)
        let visible = try #require(arts.last)
        let ahead = Task { await PatchTextures.decodeAhead(arts.dropLast(), size: .thumbnail) }
        let loaded = await PatchTextures.load(visible, size: .thumbnail)
        #expect(loaded != nil)
        #expect(arts.dropLast().contains { PatchTextures.cached($0, size: .thumbnail) == nil }, "it came before the rest of them")
        ahead.cancel()
        await ahead.value
    }

    @Test("Start's and Stop's haptic follows the run")
    func runFelt() async throws {
        let harness = try ScreenAccessibilityTests.Harness()
        #expect(!harness.run.isRunGoing)
        await harness.run.start()
        #expect(harness.run.state.isActive)
        #expect(harness.run.isRunGoing)
        await harness.run.stop()
        #expect(!harness.run.isRunGoing)
        #expect(!harness.run.hasFailed)
    }

    @Test("a sighting the outbox was told about is published, and one from before isn't")
    func published() throws {
        let harness = try ScreenAccessibilityTests.Harness()
        let identifier = UUID()
        #expect(!harness.outbox.isPublished(identifier))
        harness.outbox.added(identifier, isNewPatch: true)
        #expect(harness.outbox.isPublished(identifier))
        #expect(!harness.outbox.isPublished(UUID()))
    }
}
#endif
