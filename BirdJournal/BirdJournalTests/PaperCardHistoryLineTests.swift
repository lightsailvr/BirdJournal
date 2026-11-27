import Album
import Foundation
import Pack
import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import BirdJournal

// Issue #214's follow-up: the paper card's history line, "1 sighting here, sewn Nov 26, 2026 in North America". It wraps for
// a set whose name is that long, and a card with a story and biology is full by then, so its second line lay under the
// card's pinned footer until the card was scrolled: the card read "…sewn Nov 26, 2026 in". The real page is hosted with a
// stand-in set of each name (as `ContinentalEditionTests` stands the North America set in), the card up, and the frames
// VoiceOver is given are read where the card rests. That the friends who have the bird stay in view too is
// `GuildDataUITests.testAPaperCardNamesTheFriendsWhoHaveTheBird`.
@Suite("The paper card's history line", .serialized)
@MainActor
struct PaperCardHistoryLineTests {
    typealias Screens = ScreenAccessibilityTests

    /// The longest name is a shipped regional set's.
    nonisolated static let setNames = ["North America", "Orlando & Space Coast"]
    /// The default size and the largest at which the card still scrolls inside its footprint; then one accessibility size,
    /// where the card grows into a reading view and the page scrolls instead.
    nonisolated static let sizes: [DynamicTypeSize] = [.large, .xxxLarge, .accessibility2]

    /// Where the page's parts are on screen, by accessibility identifier, once the card's foot has been laid out.
    static func frames(setName: String, typeSize: DynamicTypeSize) async throws -> [String: CGRect] {
        let harness = try Screens.Harness(seeded: false)
        // The bundled bird with the longest story, and so the fullest card: before the fix its history was at or under the fold.
        func excerpt(_ bird: BundledPack.Bird) -> Int {
            (harness.library.species(scientificName: bird.scientificName)?.species.lore).flatMap { LoreExcerpt.front($0.text) }?.count ?? 0
        }
        let bird = try #require(BundledPack.all.max { excerpt($0) < excerpt($1) })
        #expect(excerpt(bird) > 0, "the card needs a story to be full")
        harness.album.mainContext.insert(Sighting(speciesID: bird.label, confirmedAt: .now, location: ContinentalEditionTests.kansas, soundConfidence: 0.9, source: .phone))
        try harness.album.mainContext.save()
        // A stand-in set of that name around the sighting, with the bird in it.
        let northAmerica = ContinentalEditionTests.northAmerica
        let set = CardSet(id: northAmerica.id, name: setName, edition: northAmerica.edition, species: [bird.scientificName], regions: northAmerica.regions)
        let store = CollectionStore(container: harness.album, sets: { [set] })
        let patch = try #require(store.collection.patches(in: set.id).first)

        await harness.place.prepareForLaunch()
        CardFlipAccessibilityTests.enableAccessibility()
        let host = UIHostingController(rootView: harness.hosted(PatchDetailView(key: patch.id, startsTurned: true).environment(store), typeSize: typeSize))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        defer { window.isHidden = true }
        var found: [String: CGRect] = [:]
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(250))
            found = [:]
            collect(host.view, into: &found)
            if found["card-history"] != nil, found["card-all-sightings"] != nil { break }
        }
        return found
    }

    /// Every identified element under `object`, as VoiceOver would reach it, with its frame on screen.
    private static func collect(_ object: Any, into found: inout [String: CGRect]) {
        guard let object = object as? NSObject, !object.accessibilityElementsHidden else { return }
        // SwiftUI's accessibility nodes answer the selector without adopting `UIAccessibilityIdentification`.
        let selector = #selector(getter: UIAccessibilityIdentification.accessibilityIdentifier)
        if object.responds(to: selector), let identifier = object.perform(selector)?.takeUnretainedValue() as? String, !identifier.isEmpty, found[identifier] == nil {
            found[identifier] = object.accessibilityFrame
        }
        if let elements = object.accessibilityElements, !elements.isEmpty {
            for element in elements { collect(element, into: &found) }
            return
        }
        let count = object.accessibilityElementCount()
        if count != NSNotFound, count > 0 {
            for index in 0..<count { if let element = object.accessibilityElement(at: index) { collect(element, into: &found) } }
            return
        }
        if let view = object as? UIView { for subview in view.subviews { collect(subview, into: &found) } }
    }

    @Test("the whole line is in view above the card's footer where the card rests, however long the set's name", arguments: setNames, sizes)
    func wholeAboveTheFooter(setName: String, typeSize: DynamicTypeSize) async throws {
        let frames = try await Self.frames(setName: setName, typeSize: typeSize)
        let line = try #require(frames["card-history"], "\(frames.keys.sorted())")
        let footer = try #require(frames["card-all-sightings"], "\(frames.keys.sorted())")
        #expect(line.height >= 10 && line.width >= 100, "the line is laid out: \(line)")
        #expect(line.maxY <= footer.minY + 0.5, "\(setName) at \(typeSize): the line \(line) runs under the footer \(footer)")
        if let scroll = frames["card-back-scroll"] {
            // Inside the card's scrolling text it would have to end where that ends; under it, it never scrolls away. Before the fix
            // the line was at 537 to 567 pt with the scrolling text ending at 549 and the footer starting at 551 (default size), and
            // wholly under the footer, from 805 pt, at xxxLarge.
            #expect(line.maxY <= scroll.maxY + 0.5 || line.minY >= scroll.maxY - 0.5, "\(setName) at \(typeSize): the line \(line) is cut at the foot of the scrolling text \(scroll)")
            #expect(line.minY >= scroll.minY - 0.5, "\(setName) at \(typeSize): the line \(line) is above the card \(scroll)")
            // The card is full, or this would say nothing: its latest sighting is cut off or out of view, as the line used to be.
            let sighting = try #require(frames["card-history-sighting"], "\(frames.keys.sorted())")
            #expect(sighting.maxY > scroll.maxY, "\(setName) at \(typeSize): the card isn't full, the sighting \(sighting) is in view in \(scroll)")
        } else {
            #expect(typeSize.isAccessibilitySize, "only the reading view has no scrolling text inside the card")
        }
    }
}
