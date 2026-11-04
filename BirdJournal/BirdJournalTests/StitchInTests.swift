import Album
import Foundation
import Pack
import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import BirdJournal

// Issue #135 (guide page 14): the stitch-in's clock and its threads, pure, so the pacing and the words are tested without a
// screen, then the real shader on the real pack's layers.
@Suite("Stitch-in")
struct StitchInTests {
    /// Nine threads and a cord, on bounds as a pack writes them.
    static let threads: [StitchThread] = {
        let bounds = (0...10).map { Double(round(255 * Double($0) / 10)) / 255 }
        return (0..<10).map { StitchThread(start: bounds[$0], end: bounds[$0 + 1], red: 0.7, green: 0.55, blue: 0.3, isCord: $0 == 9) }
    }()

    /// The frames of a whole stitch-in at 120 Hz.
    static func frames(of timeline: StitchTimeline) -> [StitchTimeline.Frame] {
        stride(from: 0.0, through: timeline.duration + 0.1, by: 1.0 / 120).map { timeline.frame(at: $0) }
    }

    @Test("it starts on the bare twill, with no thread laid")
    func startsBare() {
        let first = StitchTimeline(threads: Self.threads).frame(at: 0)
        #expect(first.sewnTo < 0)
        #expect(first.thread == nil)
        #expect(!first.isDone)
    }

    @Test("about 4.2 s, and done only then")
    func duration() {
        let timeline = StitchTimeline(threads: Self.threads)
        #expect(StitchTimeline.duration == 4.2)
        #expect(!timeline.frame(at: 4.19).isDone)
        #expect(timeline.frame(at: 4.2).isDone)
        #expect(timeline.frame(at: 400).isDone, "back from the background, it's finished")
        #expect(timeline.frame(at: 4.2).sewnTo >= 1, "all of it")
    }

    @Test("one thread at a time in the pack's order, each ticking once, the cord last and taking longest")
    func oneThreadAtATime() {
        let frames = Self.frames(of: StitchTimeline(threads: Self.threads))
        var seen: [Int] = []
        var lengths: [Int: Int] = [:]
        for frame in frames {
            guard let thread = frame.thread else { continue }
            if seen.last != thread { seen.append(thread) }
            lengths[thread, default: 0] += 1
        }
        #expect(seen == Array(0..<10), "each thread once, in order: \(seen)")
        let plain = lengths[3] ?? 0
        #expect(abs((lengths[0] ?? 0) - plain) <= 1, "every thread the same time, however much it fills")
        #expect((lengths[9] ?? 0) >= plain * 2 - 2, "the cord has the whole way round to go")
    }

    @Test("the thread only ever goes forward, each within its own band, and the patch is all sewn before the reveal")
    func goesForward() {
        let timeline = StitchTimeline(threads: Self.threads)
        let frames = Self.frames(of: timeline)
        for (before, after) in zip(frames, frames.dropFirst()) {
            #expect(after.sewnTo >= before.sewnTo)
        }
        for frame in frames {
            guard let thread = frame.thread, frame.sewnTo < 1 else { continue }
            #expect(Double(frame.sewnTo) >= Self.threads[thread].start - 0.0001)
            #expect(Double(frame.sewnTo) <= Self.threads[thread].end + 0.0001)
        }
        #expect(frames.contains { $0.sewnTo >= 1 && !$0.isDone }, "a moment on the finished patch before the words change")
    }

    @Test("a sweep goes round and round and is never done")
    func loops() {
        let timeline = StitchTimeline(threads: Self.threads, loops: true)
        #expect(!timeline.frame(at: 400).isDone)
        #expect(timeline.frame(at: timeline.duration * 3 + 0.01).sewnTo < 0, "back on the bare twill")
    }

    @Test("the caption names the thread, and the cord; before the first thread, the pattern")
    func captions() {
        let timeline = StitchTimeline(threads: Self.threads)
        #expect(timeline.caption(for: nil) == "Transfer pattern")
        #expect(timeline.caption(for: 4) == "Thread 5 of 10 · Ochre")
        #expect(timeline.caption(for: 9) == "Cord · Ochre")
    }

    @Test("threads get plain colour names", arguments: [
        (0.04, 0.04, 0.03, "Black"), (0.3, 0.3, 0.31, "Charcoal"), (0.55, 0.55, 0.55, "Grey"), (0.97, 0.97, 0.96, "White"),
        (0.69, 0.55, 0.32, "Ochre"), (0.72, 0.36, 0.12, "Rust"), (0.31, 0.27, 0.13, "Olive"), (0.36, 0.42, 0.18, "Forest"),
        (0.25, 0.32, 0.42, "Navy"), (0.33, 0.45, 0.62, "Slate blue"), (0.6, 0.12, 0.1, "Red"), (0.45, 0.3, 0.5, "Plum"),
    ])
    func threadNames(red: Double, green: Double, blue: Double, name: String) {
        #expect(ThreadName.of(red: red, green: green, blue: blue) == name)
    }

    @Test("the count on a seen-again page goes 7 to 8 when it ticks; on a still page it's 8 at once")
    func countTicks() {
        #expect(StitchCeremony.shownCount(of: 8, hasTicked: false, isStill: false) == 7)
        #expect(StitchCeremony.shownCount(of: 8, hasTicked: true, isStill: false) == 8)
        #expect(StitchCeremony.shownCount(of: 8, hasTicked: false, isStill: true) == 8, "Reduce Motion and VoiceOver")
        #expect(StitchCeremony.isStill(reduceMotion: true, voiceOver: false))
        #expect(StitchCeremony.isStill(reduceMotion: false, voiceOver: true))
        #expect(!StitchCeremony.isStill(reduceMotion: false, voiceOver: false))
    }

    @Test("only a stitch-in with motion, without VoiceOver and with a painting")
    func whoGetsIt() {
        #expect(StitchCeremony.stitches(reduceMotion: false, voiceOver: false, hasArt: true))
        #expect(!StitchCeremony.stitches(reduceMotion: true, voiceOver: false, hasArt: true), "Reduce Motion: the finished patch")
        #expect(!StitchCeremony.stitches(reduceMotion: false, voiceOver: true, hasArt: true), "VoiceOver: the finished patch")
        #expect(!StitchCeremony.stitches(reduceMotion: false, voiceOver: false, hasArt: false), "no painting: its blank")
    }
}

// A visual effect needs a test on pixels (issue #134's lesson): `sewnTo` going in is not the patch coming out.
@Suite("Stitch-in on screen", .serialized)
@MainActor
struct StitchInPixelTests {
    /// The House Finch, decoded, with its threads.
    static func finch() async throws -> (art: PatchArt, loaded: PatchTextures.Loaded, threads: [StitchThread], bounds: [Int]) {
        let pack = try SpeciesPack.bundled()
        let patch = try #require(pack.species(scientificName: "Haemorhous mexicanus")?.patch)
        let art = PatchArt(colour: pack.patchURL(for: patch), layers: pack.patchLayersURL(for: patch), ground: patch.ground, stitchBounds: patch.stitchBounds)
        let loaded = try #require(await PatchTextures.load(art, size: .full))
        let threads = await PatchTextures.threads(of: loaded, art: art)
        return (art, loaded, threads, patch.stitchBounds)
    }

    @Test("the real pack's threads: every band that shows, the cord last in the edition's olive, each a real colour of its own")
    func realThreads() async throws {
        let (_, _, threads, bounds) = try await Self.finch()
        #expect(threads.count >= bounds.count - 2, "\(threads.count) threads of \(bounds.count - 1) bands")
        #expect(threads.count <= bounds.count - 1)
        let cord = try #require(threads.last)
        #expect(cord.isCord)
        #expect(threads.dropLast().allSatisfy { !$0.isCord })
        #expect(["Olive", "Forest", "Moss"].contains(cord.name), "the Citrus cord, not \(cord.name)")
        #expect(Set(threads.map(\.name)).count >= 3, "not one muddy colour for all of them: \(threads.map(\.name))")
        #expect(zip(threads, threads.dropFirst()).allSatisfy { $0.end <= $1.start }, "the bands in order")
        print("House Finch threads:", threads.map(\.name))
    }

    /// `view` rendered at one point per pixel, in a window: `drawHierarchy` does run the `layerEffect`.
    static func rendered(_ view: some View, size: CGFloat = 300, width: UnsafeMutablePointer<Int>? = nil) async throws -> [UInt8] {
        let host = UIHostingController(rootView: view.frame(width: size, height: size).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black.ignoresSafeArea()))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = try UIWindow(windowScene: #require(scene))
        window.frame = CGRect(x: 0, y: 0, width: size + 100, height: size + 100)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(400))
        // A window on a scene needn't keep the frame it's given, so the width comes from what was drawn.
        width?.pointee = Int(host.view.bounds.width)
        return PatchLightPixelTests.pixels(of: host.view)
    }

    @Test("stitching lays the bird's thread by the pack's order: a third of the way along shows the order's share of the patch, and all of it is the sewn patch")
    func theOrderOnScreen() async throws {
        let (art, loaded, _, bounds) = try await Self.finch()
        PatchLight.shared.restart()
        let edition = PatchEdition.of(setID: "us-ca-la")
        func patch(_ face: PatchView.Face) -> some View { PatchView(art: art, edition: edition, face: face, size: .full) }

        let bare = try await Self.rendered(patch(.stitching(sewnTo: -0.02)))
        let sewn = try await Self.rendered(patch(.sewn))
        #expect(PatchLightPixelTests.meanChange(bare, sewn) > 8, "the bare twill isn't the patch")
        let done = try await Self.rendered(patch(.stitching(sewnTo: StitchTimeline.allSewn)))
        #expect(PatchLightPixelTests.meanChange(done, sewn) < 0.1, "all sewn is the sewn patch, with no seam when the reveal takes over")

        // A band of the order, against the fraction of the patch's own pixels at or below it. If the shader read the
        // order through a colour conversion, the share on screen would be far from the share in the file.
        for bound in [bounds[bounds.count / 3], bounds[bounds.count * 2 / 3]] {
            let sewnTo = Float(bound) / 255
            let part = try await Self.rendered(patch(.stitching(sewnTo: sewnTo)))
            let expected = try #require(Self.share(of: loaded, upTo: bound))
            let onScreen = Self.shareNearer(part, to: sewn, than: bare)
            print("order \(bound): \(expected) of the patch in the file, \(onScreen) on screen")
            #expect(abs(expected - onScreen) < 0.12, "at order \(bound): \(expected) of the patch in the file, \(onScreen) on screen")
        }
    }

    @Test("the cord comes last: before its turn the edge is bare twill, and it goes round from the top")
    func cordLast() async throws {
        let (art, _, threads, _) = try await Self.finch()
        PatchLight.shared.restart()
        let edition = PatchEdition.of(setID: "us-ca-la")
        func patch(_ face: PatchView.Face) -> some View { PatchView(art: art, edition: edition, face: face, size: .full) }
        let cord = try #require(threads.last)
        let before = try await Self.rendered(patch(.stitching(sewnTo: Float(cord.start) - 0.01)))
        var width = 0
        let sewn = try await Self.rendered(patch(.sewn), width: &width)
        let halfway = try await Self.rendered(patch(.stitching(sewnTo: Float((cord.start + cord.end) / 2))))

        // The patch's own box on the black behind it: the hosted view doesn't have to sit where the window's centre is.
        let height = sewn.count / 4 / width
        var (minX, maxX, minY, maxY) = (width, 0, height, 0)
        for y in 0..<height {
            for x in 0..<width where Int(sewn[(y * width + x) * 4]) > 60 {
                (minX, maxX, minY, maxY) = (min(minX, x), max(maxX, x), min(minY, y), max(maxY, y))
            }
        }
        #expect(maxX - minX > 280, "the patch is on screen")
        #expect(maxY - minY > 280, "the patch is on screen")
        let (midX, midY, inset) = ((minX + maxX) / 2, (minY + maxY) / 2, 5)

        /// The mean difference per pixel between two renders in a small box on the cord.
        func onCord(_ pixels: [UInt8], _ reference: [UInt8], x: Int, y: Int) -> Double {
            var total = 0
            for dy in -2...2 {
                for dx in -2...2 {
                    let at = ((y + dy) * width + x + dx) * 4
                    for channel in 0..<3 { total += abs(Int(pixels[at + channel]) - Int(reference[at + channel])) }
                }
            }
            return Double(total) / 25
        }
        let (top, bottom, right, left) = ((midX, minY + inset), (midX, maxY - inset), (maxX - inset, midY), (minX + inset, midY))
        for (place, point) in [("top", top), ("bottom", bottom), ("right", right), ("left", left)] {
            #expect(onCord(before, sewn, x: point.0, y: point.1) > 24, "no cord at the \(place) before its turn")
        }
        // Clockwise from the top: at half its band the cord has reached the right, and not yet the left.
        #expect(onCord(halfway, sewn, x: right.0, y: right.1) < 12, "the right side is sewn by halfway")
        #expect(onCord(halfway, sewn, x: left.0, y: left.1) > 24, "the left side isn't")
    }

    /// The share of the patch's pixels whose stitch order is at or below `bound`, in the decoded file.
    static func share(of loaded: PatchTextures.Loaded, upTo bound: Int) -> Double? {
        guard let layers = loaded.layersBitmap.dataProvider?.data, let colour = loaded.colourBitmap.dataProvider?.data,
              let order = CFDataGetBytePtr(layers), let paint = CFDataGetBytePtr(colour) else { return nil }
        let (width, height) = (loaded.layersBitmap.width, loaded.layersBitmap.height)
        var inside = 0, sewn = 0
        for y in 0..<height {
            for x in 0..<width {
                let alpha = paint[y * loaded.colourBitmap.height / height * loaded.colourBitmap.bytesPerRow + x * loaded.colourBitmap.width / width * 4 + 3]
                guard alpha > 128 else { continue }
                inside += 1
                if Int(order[y * loaded.layersBitmap.bytesPerRow + x * 4 + 2]) <= bound { sewn += 1 }
            }
        }
        return Double(sewn) / Double(max(inside, 1))
    }

    /// The share of the pixels that differ between `first` and `second` where `pixels` is nearer `first`.
    static func shareNearer(_ pixels: [UInt8], to first: [UInt8], than second: [UInt8]) -> Double {
        var differ = 0, nearer = 0
        for at in stride(from: 0, to: pixels.count, by: 4) {
            var toFirst = 0, toSecond = 0, between = 0
            for channel in 0..<3 {
                toFirst += abs(Int(pixels[at + channel]) - Int(first[at + channel]))
                toSecond += abs(Int(pixels[at + channel]) - Int(second[at + channel]))
                between += abs(Int(first[at + channel]) - Int(second[at + channel]))
            }
            guard between > 24 else { continue }
            differ += 1
            if toFirst < toSecond { nearer += 1 }
        }
        return Double(nearer) / Double(max(differ, 1))
    }
}

// VoiceOver through the ceremony (issue #135), by walking the accessibility tree as #52 and #119 do: XCUITest lists what
// SwiftUI hides. The system's VoiceOver can't be turned on in a test, so `voiceOverPath` stands in for it, as `reduceMotion`
// does for Reduce Motion.
@Suite("Sewing ceremony accessibility", .serialized)
@MainActor
struct SewingCeremonyAccessibilityTests {
    /// The run, showing a page for the seeded Black Phoebe in Los Angeles.
    static func harness(seenAgain count: Int? = nil) throws -> ScreenAccessibilityTests.Harness {
        let harness = try ScreenAccessibilityTests.Harness()
        let context = harness.album.mainContext
        let all = try context.fetch(Sighting.newestFirst())
        let phoebe = try #require(all.first { $0.scientificName == "Sayornis nigricans" })
        let placement = try #require(harness.library.collection(of: all).placement(of: phoebe.identifier))
        #expect(placement.setID != nil, "in the Los Angeles set")
        harness.run.showRevealForScreenshot(of: phoebe, placement: placement, seenAgain: count)
        return harness
    }

    static func withFlag<T>(_ key: String, _ value: Any, _ body: () async throws -> T) async rethrows -> T {
        UserDefaults.standard.set(value, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        return try await body()
    }

    @Test("under VoiceOver there's no stitching: the page reads the finished patch in one sentence, and its way back", arguments: ScreenAccessibilityTests.sizes)
    func voiceOverNewPatch(typeSize: DynamicTypeSize) async throws {
        let harness = try Self.harness()
        let labels = try await Self.withFlag("voiceOverPath", true) {
            try await ScreenAccessibilityTests.walk(Color.clear.patchReveal(), harness: harness, typeSize: typeSize) { labels in
                labels.contains("Done") && labels.contains { $0.hasPrefix("Your first") }
            }
        }
        ScreenAccessibilityTests.expectClean(labels, screen: "New patch")
        #expect(!labels.contains { $0.hasPrefix("Sewing") }, "no stitching: \(labels)")
        #expect(labels.contains("New patch · Citrus edition"), "\(labels)")
        #expect(labels.contains("Your first Black Phoebe in Los Angeles"), "\(labels)")
        #expect(labels.contains { $0.hasPrefix("Black Phoebe, Citrus edition patch, seen once, sewn ") }, "the patch in words: \(labels)")
        #expect(labels.contains("Done"), "no run: back to where the add was: \(labels)")
        #expect(labels.contains("Share this patch"), "\(labels)")
        #expect(harness.run.reveal?.hasPlayed == true, "decided once: it won't start stitching if VoiceOver goes off under the page")
    }

    @Test("the stitch-in, if VoiceOver does land on it, is one element that says what's happening, and activating it finishes it")
    func stitching() async throws {
        let harness = try Self.harness()
        try await Self.withFlag("stitchInSeconds", 60.0) {
            CardFlipAccessibilityTests.enableAccessibility()
            let host = UIHostingController(rootView: harness.hosted(Color.clear.patchReveal(), typeSize: .large))
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            let window = try UIWindow(windowScene: #require(scene))
            window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true }

            var labels: [String] = []
            for _ in 0..<60 {
                try await Task.sleep(for: .milliseconds(250))
                labels = ScreenAccessibilityTests.spoken(host.view)
                if labels.contains("Sewing your Black Phoebe patch") { break }
            }
            #expect(labels == ["Sewing your Black Phoebe patch"], "one element, nothing else to read over it: \(labels)")

            let element = try #require(Self.element(in: host.view, labelled: "Sewing your Black Phoebe patch"))
            #expect(element.accessibilityTraits.contains(.button))
            #expect(element.accessibilityValue?.isEmpty == false, "the thread it's on: \(String(describing: element.accessibilityValue))")
            #expect(element.accessibilityActivate())
            #expect(harness.run.reveal?.hasPlayed == true, "the page shows the finished patch from here")
            for _ in 0..<60 {
                try await Task.sleep(for: .milliseconds(250))
                labels = ScreenAccessibilityTests.spoken(host.view)
                if labels.contains("Your first Black Phoebe in Los Angeles") { break }
            }
            #expect(labels.contains("Your first Black Phoebe in Los Angeles"), "\(labels)")
            #expect(!labels.contains { $0.hasPrefix("Sewing") }, "\(labels)")
        }
    }

    @Test("seen again: the patch and its true count in words at once, the latest sightings and the way back", arguments: ScreenAccessibilityTests.sizes)
    func seenAgain(typeSize: DynamicTypeSize) async throws {
        let harness = try Self.harness(seenAgain: 8)
        let labels = try await Self.withFlag("voiceOverPath", true) {
            try await ScreenAccessibilityTests.walk(Color.clear.patchReveal(), harness: harness, typeSize: typeSize) { labels in
                labels.contains("Done") && labels.contains { $0.hasPrefix("Black Phoebe, ") }
            }
        }
        ScreenAccessibilityTests.expectClean(labels, screen: "Seen again")
        #expect(labels.contains("Seen again · Citrus edition"), "\(labels)")
        #expect(labels.contains("Seen 8 times in Los Angeles"), "the final count, not a digit going by: \(labels)")
        #expect(!labels.contains("8") && !labels.contains("7"), "\(labels)")
        #expect(labels.contains { $0.hasPrefix("Black Phoebe, Citrus edition patch, seen ") }, "\(labels)")
        #expect(labels.contains { $0.contains("Heard") || $0.contains("Seen ·") }, "a latest sighting: \(labels)")
        #expect(labels.contains { $0.hasPrefix("Sewn ") || $0.contains("earlier") }, "\(labels)")
        #expect(labels.contains("Done"), "\(labels)")
        #expect(!labels.contains { $0.hasPrefix("Sewing") }, "\(labels)")
    }

    private static func element(in object: Any, labelled label: String) -> NSObject? {
        guard let object = object as? NSObject, !object.accessibilityElementsHidden else { return nil }
        if object.isAccessibilityElement { return object.accessibilityLabel == label ? object : nil }
        if let elements = object.accessibilityElements, !elements.isEmpty {
            return elements.compactMap { Self.element(in: $0, labelled: label) }.first
        }
        let count = object.accessibilityElementCount()
        if count != NSNotFound, count > 0 {
            return (0..<count).compactMap { object.accessibilityElement(at: $0) }.compactMap { Self.element(in: $0, labelled: label) }.first
        }
        return (object as? UIView)?.subviews.compactMap { Self.element(in: $0, labelled: label) }.first
    }
}

@Suite("Reveal words")
struct RevealWordsTests {
    static let placement = CardPlacement.numbered(setID: "us-ca-la", setName: "Los Angeles", edition: "Citrus edition", number: 19, total: 160)

    @Test("the number line under the name, in a set; none outside every set")
    func numberLine() {
        #expect(PatchText.revealNumberLine(Self.placement) == "No. 019 of 160 · Los Angeles")
        #expect(PatchText.revealNumberLine(.uncharted) == nil)
    }

    @Test("a latest sighting today has its time; before today, its date")
    func latestDate() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 12)))
        let morning = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 8, minute: 3)))
        let october = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 8)))
        #expect(PatchText.latestDate(morning, now: now, calendar: calendar).hasPrefix("Today · "))
        #expect(PatchText.latestDate(morning, now: now, calendar: calendar).contains("8:03"))
        #expect(PatchText.latestDate(october, now: now, calendar: calendar) == october.formatted(.dateTime.month(.abbreviated).day()))
    }

    @Test("under the latest sightings: how many earlier and when it was sewn, or only when it was sewn")
    func earlier() throws {
        let sewn = Date(timeIntervalSince1970: 1_789_000_000)
        func patch(_ count: Int) throws -> CardCollection.Patch {
            let entries = (0..<count).map { CardCollection.Entry(identifier: UUID(), speciesID: "A b_C", confirmedAt: sewn.addingTimeInterval(Double($0) * 86_400)) }
            return try #require(CardCollection(entries).patches.first)
        }
        let date = sewn.formatted(.dateTime.month(.abbreviated).day())
        #expect(try PatchText.earlierLine(patch(8), shown: 3) == "+ 5 earlier · Sewn \(date)")
        #expect(try PatchText.earlierLine(patch(3), shown: 3) == "Sewn \(date)")
    }
}
