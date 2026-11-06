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
            for text in ["JournalInk", "JournalInkSecondary", "JournalMoss"] {
                try expect(text, on: surface, atLeast: 4.5)
            }
        }
        try expect("JournalMossText", on: "JournalMoss", atLeast: 4.5)
        try expect("JournalOnSharedGoal", on: "JournalSharedGoal", atLeast: 4.5)
    }

    @Test("the card face reads the same in both appearances and its text is at least 4.5:1")
    func cardFace() throws {
        // Card ink reads in the light scheme whatever the app's (`CardStockSurface`).
        let light = Self.variants.filter { $0.name.hasPrefix("light") }
        for text in ["CollectibleInk", "CollectibleInkSecondary", "CollectibleEdge", "JournalInk", "JournalInkSecondary", "JournalMoss"] {
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
    }
}

// Issue #134 with #52's walk: the real patch and paper card in the two-sided object, hosted in a window with app
// accessibility on, expose only the face that is up to VoiceOver.
@Suite("Paper card accessibility", .serialized)
@MainActor
struct PaperCardAccessibilityTests {
    static func page(showsBack: Bool) throws -> some View {
        let album = try AlbumSchema.makeContainer(inMemory: true)
        let griffithPark = Coordinate(latitude: 34.13, longitude: -118.29, accuracy: 10)
        let sighting = Sighting(speciesID: "Sayornis nigricans_Black Phoebe", confirmedAt: .now, location: griffithPark, soundConfidence: 0.8, source: .phone)
        album.mainContext.insert(sighting)
        let library = PackLibrary(bundled: try SpeciesPack.bundled(), storage: PackStorage(directory: URL.temporaryDirectory.appending(path: "PaperCardTests-\(UUID().uuidString)")), indexURL: PackIndex.defaultURL)
        let collection = CardCollection(sightings: [sighting], sets: library.cardSets)
        let patch = try #require(collection.patch(of: sighting.identifier))
        return NavigationStack {
            ScrollView {
                CollectibleCard(showsBack: showsBack, rotates: true) {
                    Button("Black Phoebe, Citrus edition patch") {}
                        .frame(height: 470)
                } back: {
                    PaperCardView(patch: patch, sightings: [sighting], name: "Black Phoebe", isReadingView: false)
                }
            }
        }
        .environment(library)
        .environment(PlaceNames())
        .modelContainer(album)
    }

    /// The labels VoiceOver reaches in the hosted page, walked again until `ready` holds or ten seconds pass: SwiftUI
    /// fills the accessibility tree some time after the first render, later under a full parallel test run.
    static func labels(showsBack: Bool, ready: ([String]) -> Bool) async throws -> [String] {
        CardFlipAccessibilityTests.enableAccessibility()
        let host = UIHostingController(rootView: try page(showsBack: showsBack))
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

    @Test("patch up: the patch, nothing of the card")
    func patchUp() async throws {
        let labels = try await Self.labels(showsBack: false) { $0.contains { $0.hasPrefix("Black Phoebe, Citrus") } }
        #expect(labels.contains { $0.hasPrefix("Black Phoebe, Citrus") }, "\(labels)")
        #expect(!labels.contains { $0.hasPrefix("All 1") }, "\(labels)")
        #expect(!labels.contains("Sources"), "\(labels)")
    }

    @Test("card up: the edition, the names, the story, the biology, the history and the footer, nothing of the patch")
    func cardUp() async throws {
        let labels = try await Self.labels(showsBack: true) { $0.contains("Sources") && $0.contains { $0.hasPrefix("1 sighting here") } }
        #expect(labels.contains { $0.hasPrefix("Citrus edition, number ") }, "the edition line: \(labels)")
        #expect(labels.contains("Black Phoebe"), "\(labels)")
        #expect(labels.contains("Sayornis nigricans"), "\(labels)")
        #expect(labels.contains { $0.hasPrefix("Wherever the black phoebe keeps house") || $0.hasPrefix("Where water runs") }, "the excerpt: \(labels)")
        #expect(labels.contains { $0.hasPrefix("Wingspan") }, "the biology: \(labels)")
        #expect(labels.contains { $0.hasPrefix("1 sighting here, sewn ") }, "the history: \(labels)")
        #expect(labels.contains { $0.hasPrefix("1 sighting") }, "the footer: \(labels)")
        #expect(labels.contains("AI illustration"), "the footer: \(labels)")
        #expect(labels.contains("Sources"), "the footer: \(labels)")
        #expect(!labels.contains { $0.hasPrefix("Black Phoebe, Citrus") }, "\(labels)")
    }

    @Test("what's left of the lore follows the excerpt without repeating it")
    func restOfLore() throws {
        let long = "One short opening sentence here. " + LoreExcerptTests.sentence(30) + " " + LoreExcerptTests.sentence(30)
        let excerpt = try #require(LoreExcerpt.front(long))
        let rest = try #require(PatchText.restOfLore(long))
        #expect(excerpt + " " + rest == long)
        #expect(PatchText.restOfLore(LoreExcerptTests.sentence(30)) == nil, "the excerpt took it all")
    }

    @Test("biology lists wingspan, weight, diet, nest, clutch and size, in that order, for the bundled finch")
    func biology() throws {
        let finch = try #require(try SpeciesPack.bundled().species(scientificName: "Haemorhous mexicanus"))
        #expect(PatchText.biology(finch).map(\.label) == ["Wingspan", "Weight", "Diet", "Nest", "Clutch", "Size"])
        #expect(PatchText.biology(nil).isEmpty, "a bird no pack describes")
    }
}

// Issue #134 (guide pages 6, 11 and 14): the words around a patch, and the board's columns.
@Suite("Patch words and layout")
@MainActor
struct PatchWordsTests {
    static let set = CardSet(id: "us-ca-la", name: "Los Angeles", edition: "Citrus edition", species: ["Sayornis nigricans", "Haemorhous mexicanus"], regions: [
        CardSet.Region(name: "LA", polygons: [[[
            CardSet.Point(longitude: -119, latitude: 33), CardSet.Point(longitude: -117, latitude: 33), CardSet.Point(longitude: -117, latitude: 35), CardSet.Point(longitude: -119, latitude: 35), CardSet.Point(longitude: -119, latitude: 33),
        ]]]),
    ])

    static func patch(count: Int, at location: Coordinate?) throws -> CardCollection.Patch {
        let start = Date(timeIntervalSince1970: 1_789_000_000)
        let entries = (0..<count).map { CardCollection.Entry(identifier: UUID(), speciesID: "Haemorhous mexicanus_House Finch", confirmedAt: start.addingTimeInterval(Double($0) * 86400), location: location) }
        return try #require(CardCollection(entries, sets: [Self.set]).patches.first)
    }

    @Test("VoiceOver reads a patch as one sentence, as the guide writes it")
    func spoken() throws {
        let griffith = Coordinate(latitude: 34.13, longitude: -118.29, accuracy: 10)
        let spoken = PatchText.spoken(try Self.patch(count: 8, at: griffith), name: "House Finch")
        #expect(spoken.hasPrefix("House Finch, Citrus edition patch, seen 8 times, sewn "), "\(spoken)")
        #expect(PatchText.spoken(try Self.patch(count: 1, at: nil), name: "House Finch").hasPrefix("House Finch, Uncharted patch, seen once, sewn "))
    }

    @Test("a tile's line carries the number and the count; Uncharted has no number")
    func tileLine() throws {
        let griffith = Coordinate(latitude: 34.13, longitude: -118.29, accuracy: 10)
        #expect(PatchText.tileLine(try Self.patch(count: 8, at: griffith)) == "No. 002 · seen 8×")
        #expect(PatchText.tileLine(try Self.patch(count: 3, at: nil)) == "seen 3×")
        // Nothing about the count until there's a second sighting (issue #150).
        #expect(PatchText.tileLine(try Self.patch(count: 1, at: griffith)) == "No. 002")
        #expect(PatchText.tileLine(try Self.patch(count: 1, at: nil)) == "Uncharted")
        #expect(PatchText.editionLine(try Self.patch(count: 1, at: griffith).placement) == "Citrus edition · No. 002")
        #expect(PatchText.editionLine(.uncharted) == "Uncharted")
    }

    @Test("the board takes three columns, two as the text grows, one at accessibility sizes")
    func columns() {
        #expect(PatchBoardLayout.columns(for: .large) == 3)
        #expect(PatchBoardLayout.columns(for: .xLarge) == 3)
        #expect(PatchBoardLayout.columns(for: .xxLarge) == 2)
        #expect(PatchBoardLayout.columns(for: .xxxLarge) == 2)
        #expect(PatchBoardLayout.columns(for: .accessibility1) == 1)
    }

    @Test("every edition has its own silhouette; Uncharted is the plain round; an unknown set too")
    func editions() {
        let ids = ["us-ca-la", "us-ca-sd", "us-ca-bay", "us-ca-desert", "us-fl-orlando"]
        #expect(Set(ids.map { "\(PatchEdition.of(setID: $0).shape)" }).count == ids.count)
        #expect(PatchEdition.of(setID: nil).shape == .circle)
        #expect(PatchEdition.of(setID: nil) == PatchEdition.of(setID: "somewhere-new"))
        #expect(PatchEdition.of(setID: "us-ca-la").shape == .circle)
        #expect(PatchEdition.of(setID: "us-fl-orlando").shape == .shield)
    }

    @Test("a painting is only ever its own edition's")
    func artIsTheEditions() throws {
        let library = PackLibrary(bundled: try SpeciesPack.bundled(), storage: PackStorage(directory: URL.temporaryDirectory.appending(path: "PatchWordsTests-\(UUID().uuidString)")), indexURL: PackIndex.defaultURL)
        let art = try #require(library.patchArt(scientificName: "Haemorhous mexicanus", setID: "us-ca-la"))
        #expect(art.colour.lastPathComponent == "haemorhous-mexicanus.avif")
        #expect(art.layers.lastPathComponent == "haemorhous-mexicanus-layers.avif")
        #expect(library.patchArt(scientificName: "Haemorhous mexicanus", setID: "us-ca-sd") == nil)
        #expect(library.patchArt(scientificName: "Haemorhous mexicanus", setID: nil) == nil)
    }

    @Test("the bundled pack's patch decodes at both sizes, with its alpha, for the shader")
    func decodes() async throws {
        let library = PackLibrary(bundled: try SpeciesPack.bundled(), storage: PackStorage(directory: URL.temporaryDirectory.appending(path: "PatchWordsTests-\(UUID().uuidString)")), indexURL: PackIndex.defaultURL)
        let art = try #require(library.patchArt(scientificName: "Haemorhous mexicanus", setID: "us-ca-la"))
        let full = await PatchTextures.load(art, size: .full)
        let small = await PatchTextures.load(art, size: .thumbnail)
        #expect(full != nil)
        #expect(small != nil)
        #expect(abs((try #require(full)).texel.width - 1.0 / 360) < 0.0001)
        #expect(abs((try #require(small)).texel.width - 1.0 / 180) < 0.0001)
    }
}

// Issue #134: a board asks for many decodes at once. On Swift's cooperative pool they held every thread and hung the host.
@Suite("Patch decoding")
@MainActor
struct PatchDecodingTests {
    @Test("a whole set decoding at once finishes, and a repeat comes from the cache", .timeLimit(.minutes(2)))
    func manyAtOnce() async throws {
        let pack = try SpeciesPack.bundled()
        let arts = pack.species.compactMap(\.patch).map { PatchArt(colour: pack.patchURL(for: $0), layers: pack.patchLayersURL(for: $0), ground: $0.ground) }
        #expect(arts.count == pack.species.count)
        await withTaskGroup(of: Bool.self) { group in
            for art in arts.prefix(60) {
                group.addTask { await PatchTextures.load(art, size: .thumbnail) != nil }
            }
            for await loaded in group {
                #expect(loaded)
            }
        }
        #expect(PatchTextures.cached(arts[0], size: .thumbnail) != nil)
        #expect(PatchTextures.cached(arts[0], size: .full) == nil, "each size on its own")
    }

    @Test("a task cancelled before its turn gives nothing and caches nothing")
    func cancelled() async throws {
        let pack = try SpeciesPack.bundled()
        let patch = try #require(pack.species.last?.patch)
        let art = PatchArt(colour: pack.patchURL(for: patch), layers: pack.patchLayersURL(for: patch), ground: patch.ground)
        let task = Task { @MainActor in
            await withUnsafeContinuation { (resume: UnsafeContinuation<Void, Never>) in
                resume.resume()
            }
            return await PatchTextures.load(art, size: .full)
        }
        task.cancel()
        #expect(await task.value == nil)
        #expect(PatchTextures.cached(art, size: .full) == nil)
    }
}
