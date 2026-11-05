import Album
import Foundation
import Pack
import SwiftUI
import Testing
import UIKit
@testable import BirdJournal

// Issue #138, guide page 15: what a patch you did find shows without its painting, and the words around it.
@Suite("Patch states")
struct PatchStatesTests {
    private static let art = PatchArt(colour: URL(filePath: "/colour.avif"), layers: URL(filePath: "/layers.avif"), ground: "#C4A068")

    @Test("a painting on the phone is the patch, whatever its pack is doing")
    func painted() {
        #expect(PatchArtState.of(art: Self.art, setID: "us-ca-la", transfer: nil) == .painted(Self.art))
        #expect(PatchArtState.of(art: Self.art, setID: "us-ca-la", transfer: .downloading(received: 10)) == .painted(Self.art))
    }

    @Test("no painting while its edition's pack is on its way: being sewn", arguments: [PackLibrary.Status.downloading(received: 0), .installing])
    func beingSewn(transfer: PackLibrary.Status) {
        #expect(PatchArtState.of(art: nil, setID: "us-ca-sd", transfer: transfer) == .beingSewn)
    }

    @Test("no painting and nothing on its way: the blank with its paper tag, never an error", arguments: [
        PackLibrary.Status.notInstalled, .failed("The network went away"), .needsNewerApp, .installed(version: 3), .bundled,
    ])
    func tagged(transfer: PackLibrary.Status) {
        #expect(PatchArtState.of(art: nil, setID: "us-ca-sd", transfer: transfer) == .tagged)
    }

    @Test("Uncharted has no pack, so nothing can be on its way")
    func uncharted() {
        #expect(PatchArtState.of(art: nil, setID: nil, transfer: nil) == .tagged)
        #expect(PatchArtState.of(art: nil, setID: nil, transfer: .downloading(received: 0)) == .tagged)
    }

    @Test("Uncharted is the plain canvas round with the brown cord; a set's edition isn't canvas")
    func unchartedEdition() {
        let uncharted = PatchEdition.of(setID: nil)
        #expect(uncharted.isCanvas)
        #expect(uncharted.shape == .circle)
        #expect(uncharted.cord == Color(hex: 0x6E4B2E))
        #expect(!PatchEdition.of(setID: "us-ca-la").isCanvas)
    }

    // MARK: - Words

    private static let now = Date(timeIntervalSince1970: 1_789_000_000) // September 2026.
    private static let sewnThisYear = DateComponents(calendar: .current, year: 2026, month: 9, day: 14, hour: 12).date!
    private static let sewnLastYear = DateComponents(calendar: .current, year: 2025, month: 9, day: 14, hour: 12).date!

    @Test("VoiceOver's sentence is the guide's: the year only when it isn't this year's")
    func spoken() {
        #expect(PatchText.spoken(name: "House Finch", edition: "Citrus edition", count: 8, sewn: Self.sewnThisYear, now: Self.now) == "House Finch, Citrus edition patch, seen 8 times, sewn September 14")
        #expect(PatchText.spoken(name: "House Finch", edition: "Citrus edition", count: 1, sewn: Self.sewnLastYear, now: Self.now) == "House Finch, Citrus edition patch, seen once, sewn September 14, 2025")
    }

    @Test("a patch being sewn says so")
    func spokenBeingSewn() {
        #expect(PatchText.spoken(name: "House Finch", edition: "Coastal edition", count: 1, sewn: Self.sewnThisYear, beingSewn: true, now: Self.now) == "House Finch, Coastal edition patch, seen once, sewn September 14, art on its way")
    }

    @Test("the paper card names Uncharted as the guide writes it; a set's edition stays its own")
    func cardEdition() {
        #expect(PatchText.cardEdition(.uncharted) == "Uncharted · outside every set")
        #expect(PatchText.cardEdition(.numbered(setID: "us-ca-la", setName: "Los Angeles", edition: "Citrus edition", number: 3, total: 160)) == "Citrus edition")
    }

    @Test("a bird not yet found is numbered in every set that lists it, and in none that doesn't")
    func notYetFoundNumbers() throws {
        let bundled = try #require(try SpeciesPack.bundled().set)
        let first = try #require(bundled.species.first)
        #expect(PatchText.setNumbers(of: first.scientificName, in: [bundled]) == [
            PatchText.SetNumber(text: "No. 001 of \(bundled.species.count) · \(bundled.name)", spoken: "Number 1 of \(bundled.species.count) in \(bundled.name)"),
        ])
        #expect(PatchText.setNumbers(of: "Turdus merula", in: [bundled]).isEmpty)
    }
}
