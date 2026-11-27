import Album
import Foundation
import Pack
import SwiftUI
import Testing
@testable import BirdJournal

/// Issue #223 (of #206): what VoiceOver reads of a field guide's offer, where the birder sees their place and on the set's page.
/// The screens are hosted and their accessibility tree walked, as `ScreenAccessibilityTests` does (XCUITest lists views that
/// VoiceOver never reaches). The birder stands in Joshua Tree, in a set the phone knows from the index and has no field guide for.
@Suite("A field guide's offer, read by VoiceOver", .serialized)
@MainActor
struct FieldGuideOfferAccessibilityTests {
    typealias Screens = ScreenAccessibilityTests

    static let joshuaTree = Coordinate(latitude: 33.8734, longitude: -115.9010, accuracy: 10)

    /// The app's objects with the desert set's field guide listed as a 173 MB download, and the birder standing in the desert.
    /// Each test reads the place first, as Listen does when it comes to the front: a hosted page is never in front.
    static func harness() throws -> (harness: Screens.Harness, set: PackSet) {
        let definition = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "packbuilder/packs/us-ca-desert/set.json")
        let set = try PackSet.decode(from: Data(contentsOf: definition))
        let index = PackIndex(packs: [PackDescriptor(id: set.id, name: set.name, version: 1, url: URL(string: "https://example.invalid/desert.zip")!, sha256: "ab", byteCount: 173_000_000, set: set)])
        return (try Screens.Harness(seeded: false, index: index, standingAt: joshuaTree), set)
    }

    /// The offer's four elements, in the order VoiceOver reaches them.
    static func offer(for set: PackSet) -> [String] {
        ["You're in the \(set.name) set", FieldGuideOfferCard.placeMessage(set), "Download, 173 MB", "Not now"]
    }

    @Test("on Listen, under the local set: its words, Download with the size, and Not now, each reached once", arguments: Screens.sizes)
    func onListen(typeSize: DynamicTypeSize) async throws {
        let (harness, set) = try Self.harness()
        await harness.place.refresh()
        let labels = try await Screens.walk(ListenView(), harness: harness, typeSize: typeSize) { $0.contains("Not now") }
        Screens.expectClean(labels, screen: "Listen with an offer")
        Screens.expectOneWordPerThing(labels, screen: "Listen with an offer")
        let local = try #require(labels.firstIndex(of: "Your local set, \(set.name)"), "\(labels)")
        #expect(Array(labels[local...]).filter(Self.offer(for: set).contains) == Self.offer(for: set), "after the local set, in order: \(labels)")
        #expect(labels.filter { $0 == "Not now" || $0.hasPrefix("Download") }.count == 2, "both actions, once each: \(labels)")
        #expect(!labels.contains(LocalSetSection.notOnPhoneText), "the offer says it: \(labels)")
    }

    @Test("on the set's page, in place of its ordinary Download", arguments: Screens.sizes)
    func onTheSetsPage(typeSize: DynamicTypeSize) async throws {
        let (harness, set) = try Self.harness()
        await harness.place.refresh()
        let labels = try await Screens.walk(SetView(id: set.id), harness: harness, typeSize: typeSize) { $0.contains("Not now") }
        Screens.expectClean(labels, screen: "Set page with an offer")
        Screens.expectOneWordPerThing(labels, screen: "Set page with an offer")
        #expect(labels.filter(Self.offer(for: set).contains) == Self.offer(for: set), "\(labels)")
        #expect(labels.filter { $0.hasPrefix("Download") }.count == 1, "one Download: \(labels)")
        #expect(!labels.contains(SetView.notOnPhoneText(canDownload: true)), "\(labels)")
    }

    @Test("dismissed, both pages go back to their plain words, and the set's page keeps its Download")
    func dismissed() async throws {
        let (harness, set) = try Self.harness()
        await harness.place.refresh()
        harness.offers.dismiss(setID: set.id)
        let listen = try await Screens.walk(ListenView(), harness: harness) { $0.contains(LocalSetSection.notOnPhoneText) }
        #expect(listen.contains(LocalSetSection.notOnPhoneText), "\(listen)")
        #expect(!listen.contains("Not now") && !listen.contains { $0.hasPrefix("Download") }, "\(listen)")
        let page = try await Screens.walk(SetView(id: set.id), harness: harness) { $0.contains("Download, 173 MB") }
        #expect(page.contains("Download, 173 MB") && page.contains(SetView.notOnPhoneText(canDownload: true)), "\(page)")
        #expect(!page.contains("Not now") && !page.contains("You're in the \(set.name) set"), "\(page)")
    }
}
