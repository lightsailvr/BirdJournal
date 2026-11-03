import Album
import Foundation
import Pack
import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import BirdJournal

// Issue #116, design guide pages 5 and 17: the front's lore excerpt is the leading whole sentences of the approved
// lore, about 25–40 words, never cut inside a sentence.
@Suite("Lore excerpt")
struct LoreExcerptTests {
    /// One sentence of exactly `words` words.
    static func sentence(_ words: Int, ending: String = ".") -> String {
        (["The"] + Array(repeating: "bird", count: max(words - 1, 0))).joined(separator: " ") + ending
    }

    static func lore(_ lengths: [Int]) -> String {
        lengths.map { sentence($0) }.joined(separator: " ")
    }

    @Test("whole sentences up to 40 words, stopping before the one that would pass it")
    func upToForty() throws {
        #expect(LoreExcerpt.front(Self.lore([12, 12, 12, 12])) == Self.lore([12, 12, 12]))
        #expect(LoreExcerpt.front(Self.lore([20, 20, 5])) == Self.lore([20, 20]))
        #expect(LoreExcerpt.front(Self.lore([30, 11])) == Self.lore([30]), "41 words is past the target; 30 is enough")
    }

    @Test("a thin opening under 25 words takes one more sentence, up to 50")
    func stretch() {
        #expect(LoreExcerpt.front(Self.lore([10, 8, 30])) == Self.lore([10, 8, 30]), "18 words is thin; 48 fits the stretch")
        #expect(LoreExcerpt.front(Self.lore([10, 45])) == Self.lore([10]), "55 words would be past the stretch")
        #expect(LoreExcerpt.front(Self.lore([26, 20])) == Self.lore([26]), "26 words is enough, no stretch")
    }

    @Test("a first sentence longer than the target is kept whole, never cut")
    func longFirstSentence() {
        #expect(LoreExcerpt.front(Self.lore([60, 10])) == Self.sentence(60))
    }

    @Test("questions and exclamations end sentences too; no lore, no excerpt")
    func punctuation() {
        // 11 words is thin, but 45 more would pass the stretch.
        let lore = "Listen at the marsh edge! Is that a hen mallard calling? " + Self.lore([45])
        #expect(LoreExcerpt.front(lore) == "Listen at the marsh edge! Is that a hen mallard calling?")
        #expect(LoreExcerpt.front("") == nil)
        #expect(LoreExcerpt.front("   ") == nil)
    }

    @Test("every bundled Los Angeles species: the excerpt opens the lore, ends a sentence and runs 25 to 50 words")
    func bundledPack() throws {
        let pack = try SpeciesPack.bundled()
        let species = pack.species.filter { $0.lore != nil }
        #expect(species.count >= 150, "the bundled pack carries lore")
        var lengths: [Int] = []
        for entry in species {
            let lore = try #require(entry.lore).text
            let excerpt = try #require(LoreExcerpt.front(lore), "\(entry.scientificName)")
            let words = LoreExcerpt.wordCount(excerpt)
            lengths.append(words)
            #expect(lore.hasPrefix(excerpt), "\(entry.scientificName): \(excerpt)")
            #expect([".", "!", "?", "\"", "”"].contains(String(excerpt.last ?? " ")), "\(entry.scientificName) ends mid-sentence: \(excerpt)")
            #expect((LoreExcerpt.minimumWords...LoreExcerpt.stretchWords).contains(words), "\(entry.scientificName): \(words) words")
        }
        let withinTarget = lengths.filter { $0 <= LoreExcerpt.targetWords }.count
        #expect(Double(withinTarget) / Double(lengths.count) > 0.8, "most excerpts are within 40 words")
    }
}

// Issue #116, design guide page 9: the guide's tokens are starting points; every text pairing is measured here in all
// four variants (light, dark, and each with Increase Contrast).
@Suite("Design tokens")
@MainActor
struct DesignTokenTests {
    static let variants: [(name: String, traits: UITraitCollection)] = [UIUserInterfaceStyle.light, .dark].flatMap { style in
        [UIAccessibilityContrast.normal, .high].map { contrast in
            ("\(style == .dark ? "dark" : "light")\(contrast == .high ? " + Increase Contrast" : "")", UITraitCollection { traits in
                traits.userInterfaceStyle = style
                traits.accessibilityContrast = contrast
            })
        }
    }

    static func color(_ name: String, _ traits: UITraitCollection) throws -> UIColor {
        try #require(UIColor(named: name, in: .main, compatibleWith: traits), "no colour \(name)").resolvedColor(with: traits)
    }

    /// WCAG 2 contrast ratio.
    static func contrast(_ a: UIColor, _ b: UIColor) -> Double {
        func luminance(_ color: UIColor) -> Double {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            func linear(_ c: CGFloat) -> Double { c <= 0.04045 ? Double(c) / 12.92 : pow((Double(c) + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }
        let (l1, l2) = (luminance(a), luminance(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    func expect(_ foreground: String, on background: String, atLeast minimum: Double, in variants: [(name: String, traits: UITraitCollection)] = variants) throws {
        for variant in variants {
            let ratio = Self.contrast(try Self.color(foreground, variant.traits), try Self.color(background, variant.traits))
            #expect(ratio >= minimum, "\(foreground) on \(background), \(variant.name): \(String(format: "%.2f", ratio)):1")
        }
    }

    @Test("text on the page and on a raised surface is at least 4.5:1")
    func pageText() throws {
        for surface in ["JournalPaper", "JournalRaised"] {
            for text in ["JournalInk", "JournalInkSecondary", "JournalMoss", "CollectibleGoldInk"] {
                try expect(text, on: surface, atLeast: 4.5)
            }
        }
        try expect("JournalMossText", on: "JournalMoss", atLeast: 4.5)
        try expect("JournalInk", on: "CollectibleGoldWash", atLeast: 4.5)
        try expect("JournalOnSharedGoal", on: "JournalSharedGoal", atLeast: 4.5)
    }

    @Test("the card face reads the same in both appearances and its text is at least 4.5:1")
    func cardFace() throws {
        // The face draws in the light scheme whatever the app's (`CardSurface`).
        let light = Self.variants.filter { $0.name.hasPrefix("light") }
        for text in ["CollectibleInk", "CollectibleInkSecondary", "CollectibleEdge", "CollectibleGoldInk", "JournalInk", "JournalInkSecondary", "JournalMoss"] {
            try expect(text, on: "CollectibleFace", atLeast: 4.5, in: light)
        }
        for variant in Self.variants {
            let face = try Self.color("CollectibleFace", variant.traits)
            let lightFace = try Self.color("CollectibleFace", UITraitCollection { $0.accessibilityContrast = variant.traits.accessibilityContrast })
            #expect(face == lightFace, "the face is fixed across appearances (\(variant.name))")
        }
    }

    @Test("a card's edge shows on the light page; rules strengthen under Increase Contrast")
    func edgesAndRules() throws {
        try expect("CollectibleEdge", on: "JournalPaper", atLeast: 3, in: Self.variants.filter { $0.name.hasPrefix("light") })
        try expect("JournalRule", on: "JournalPaper", atLeast: 3, in: Self.variants.filter { $0.name.hasSuffix("Increase Contrast") })
    }

    @Test("the guide's page values hold where it set them")
    func guideValues() throws {
        let light = Self.variants[0].traits
        let dark = Self.variants[2].traits
        func hex(_ name: String, _ traits: UITraitCollection) throws -> String {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            try Self.color(name, traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
        }
        #expect(try hex("JournalPaper", dark) == "#10292D")
        #expect(try hex("JournalPaper", light) == "#F4F2E9")
        #expect(try hex("JournalRaised", dark) == "#193A3D")
        #expect(try hex("JournalRaised", light) == "#DFEAE5")
        #expect(try hex("JournalInk", dark) == "#F5F1E7")
        #expect(try hex("JournalInk", light) == "#15363A")
        #expect(try hex("JournalMoss", dark) == "#BCE3D9")
        #expect(try hex("JournalMoss", light) == "#15363A")
        #expect(try hex("JournalSharedGoal", dark) == "#B9BEDD")
        #expect(try hex("JournalSharedGoal", light) == "#E8E6F0")
        #expect(try hex("CollectibleGoldInk", dark) == "#D3B475")
    }
}

// Issue #116 with #52's walk: the real front and back in the two-sided card, hosted in a window with app
// accessibility on, expose only the face that is up to VoiceOver.
@Suite("Story card accessibility", .serialized)
@MainActor
struct StoryCardAccessibilityTests {
    static func card(showsBack: Bool) throws -> some View {
        let album = try AlbumSchema.makeContainer(inMemory: true)
        let sighting = Sighting(speciesID: "Sayornis nigricans_Black Phoebe", confirmedAt: .now, soundConfidence: 0.8, source: .phone)
        album.mainContext.insert(sighting)
        let library = PackLibrary(bundled: try SpeciesPack.bundled(), storage: PackStorage(directory: URL.temporaryDirectory.appending(path: "StoryCardTests-\(UUID().uuidString)")), indexURL: PackIndex.defaultURL)
        let edits = JournalEdits(container: album, frames: FrameStore(directory: URL.temporaryDirectory))
        return ScrollView {
            CollectibleCard(showsBack: showsBack, rotates: true) {
                CardFront(sighting: sighting, isLegendary: true, placement: nil, place: "Griffith Park")
            } back: {
                CardBack(sighting: sighting, isLegendary: true, placement: nil, showOriginal: {})
            }
        }
        .environment(library)
        .environment(PlaceNames())
        .environment(edits)
        .modelContainer(album)
    }

    /// The labels VoiceOver reaches in the hosted card, walked again until `ready` holds or ten seconds pass: SwiftUI
    /// fills the accessibility tree some time after the first render, later under a full parallel test run.
    static func labels(showsBack: Bool, ready: ([String]) -> Bool) async throws -> [String] {
        CardFlipAccessibilityTests.enableAccessibility()
        let host = UIHostingController(rootView: try card(showsBack: showsBack))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 900))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        defer { window.isHidden = true }
        var labels: [String] = []
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(250))
            labels = CardFlipAccessibilityTests.accessibleLabels(host.view)
            if ready(labels) { break }
        }
        return labels
    }

    @Test("front up: the art, the names and the excerpt, nothing of the back")
    func front() async throws {
        let labels = try await Self.labels(showsBack: false) { $0.contains("Card art: AI illustration") && $0.contains { $0.hasPrefix("Black Phoebe") } }
        #expect(labels.contains("Card art: AI illustration"), "\(labels)")
        #expect(labels.contains { $0.hasPrefix("Black Phoebe") }, "\(labels)")
        #expect(labels.contains { $0.hasPrefix("Wherever the black phoebe keeps house") || $0.hasPrefix("Where water runs") }, "the excerpt: \(labels)")
        #expect(!labels.contains("Encounter story"), "\(labels)")
        #expect(!labels.contains { $0.hasPrefix("Tagline:") }, "\(labels)")
    }

    @Test("back up: the encounter, the lore and the natural history, nothing of the front")
    func back() async throws {
        let labels = try await Self.labels(showsBack: true) { $0.contains("Encounter story") && $0.contains("Natural history") }
        #expect(labels.contains("Encounter story"), "\(labels)")
        #expect(labels.contains { $0.hasPrefix("Tagline:") }, "\(labels)")
        #expect(labels.contains("Natural history"), "\(labels)")
        #expect(!labels.contains("Card art: AI illustration"), "\(labels)")
    }
}
