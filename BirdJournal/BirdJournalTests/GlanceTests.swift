import Album
import Foundation
import Identification
import ImageIO
import Pack
import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import BirdJournal

// Issue #150: what shows outside the app. The Live Activity draws a run snapshot, and the widget a widget snapshot and a flat
// picture, so both are tested as values, with the real coordinator and the real album behind them; ActivityKit and WidgetKit
// are checked by hand on a phone.
private func waitUntil(_ what: String, timeout: Duration = .seconds(30), _ condition: () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        guard clock.now < deadline else { throw ListeningSessionTests.TimedOut(what: what) }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// Southern California, as a set's boundary.
private let southernCalifornia = CardSet.Region(name: "Los Angeles", polygons: [[[
    .init(longitude: -119, latitude: 33), .init(longitude: -117, latitude: 33), .init(longitude: -117, latitude: 35), .init(longitude: -119, latitude: 35), .init(longitude: -119, latitude: 33),
]]])

@Suite("The run snapshot and its Live Activity")
@MainActor
struct RunSnapshotTests {
    private static let griffith = Coordinate(latitude: 34.1365, longitude: -118.2942, accuracy: 15)
    private static let finch = "Haemorhous mexicanus_House Finch"
    private static let jay = "Aphelocoma californica_California Scrub-Jay"
    private static let la = CardSet(id: "us-ca-la", name: "Los Angeles", edition: "Citrus edition", species: ["Haemorhous mexicanus", "Aphelocoma californica"], regions: [southernCalifornia])

    @Test("each state of a run reads as a phase, and only a run under way has an activity")
    func phases() {
        let snapshot = { (state: ListeningCoordinator.State) in RunSnapshot(state: state, clockStart: nil, hunt: RunHunt(newPatches: 0, alreadyHave: 0), at: nil, sets: []) }
        #expect(snapshot(.idle).phase == .idle)
        #expect(!snapshot(.idle).isRunning)
        #expect(snapshot(.starting).phase == .starting)
        #expect(snapshot(.listening).phase == .listening)
        #expect(snapshot(.listening).isRunning)
        #expect(snapshot(.stopping).isRunning)
        #expect(snapshot(.ended(.stopped)).phase == .ended)
        #expect(!snapshot(.ended(.failed("No"))).isRunning)
        #expect(!snapshot(.ended(.endedByGlasses)).isRunning)
        #expect(snapshot(.interrupted).phase == .paused)
        #expect(snapshot(.paused(.glassesOff)).statusText == "Paused: glasses off")
        #expect(snapshot(.paused(.glassesOff)).isRunning)
    }

    @Test("it counts what the run's hunt counts, and the place picks the edition")
    func newPatchesAndEdition() {
        let start = Date(timeIntervalSince1970: 1_000)
        var snapshot = RunSnapshot(state: .listening, clockStart: start, hunt: RunHunt(newPatches: 2, alreadyHave: 0), at: Self.griffith, sets: [Self.la])
        #expect(snapshot.startedAt == start)
        #expect(snapshot.birdsHeard == 2)
        #expect(snapshot.newPatchesWaiting == 2)
        #expect(snapshot.setID == "us-ca-la")
        #expect(snapshot.birdsHeardText == "2 birds heard")
        #expect(snapshot.newPatchesText == RunHunt(newPatches: 2, alreadyHave: 0).waiting)

        snapshot = RunSnapshot(state: .listening, clockStart: start, hunt: RunHunt(newPatches: 1, alreadyHave: 1), at: Self.griffith, sets: [Self.la])
        #expect(snapshot.birdsHeard == 2)
        #expect(snapshot.newPatchesText == "1 new patch waiting")
        #expect(snapshot.newPatchesText == RunHunt(newPatches: 1, alreadyHave: 1).waiting)
        #expect(snapshot.spokenText == "Listening, 2 birds heard, 1 new patch waiting")

        snapshot = RunSnapshot(state: .listening, clockStart: start, hunt: RunHunt(newPatches: 0, alreadyHave: 2), at: Self.griffith, sets: [Self.la])
        #expect(snapshot.newPatchesText == nil, "the line says nothing with none waiting")
        #expect(snapshot.spokenText == "Listening, 2 birds heard")
    }

    @Test("outside every set, or before a fix, the run has no edition")
    func noEdition() {
        let hunt = RunHunt(newPatches: 0, alreadyHave: 0)
        #expect(RunSnapshot(state: .listening, clockStart: nil, hunt: hunt, at: nil, sets: [Self.la]).setID == nil)
        #expect(RunSnapshot(state: .listening, clockStart: nil, hunt: hunt, at: Coordinate(latitude: 40.7, longitude: -74, accuracy: 10), sets: [Self.la]).setID == nil)
    }

    private final class FakeHost: RunActivityHost {
        enum Call: Equatable {
            case begin(RunSnapshot)
            case update(RunSnapshot)
            case end(RunSnapshot)
            case leftovers
        }

        var calls: [Call] = []
        var refuses = false
        func begin(_ snapshot: RunSnapshot) -> Bool {
            calls.append(.begin(snapshot))
            return !refuses
        }
        func update(_ snapshot: RunSnapshot) { calls.append(.update(snapshot)) }
        func end(_ snapshot: RunSnapshot) { calls.append(.end(snapshot)) }
        func endLeftovers() { calls.append(.leftovers) }
    }

    @Test("one activity begins with a run, changes only when the snapshot does, ends with the run, and the next run gets its own")
    func controllerRule() {
        let host = FakeHost()
        let controller = RunActivityController(host: host)
        let starting = RunSnapshot(phase: .starting, startedAt: nil, birdsHeard: 0, newPatchesWaiting: 0)
        var listening = RunSnapshot(phase: .listening, startedAt: .now, birdsHeard: 0, newPatchesWaiting: 0)
        let ended = RunSnapshot(phase: .ended, startedAt: listening.startedAt, birdsHeard: 1, newPatchesWaiting: 0)

        controller.apply(.idle)
        #expect(host.calls.isEmpty, "no run, no activity")
        controller.apply(starting)
        controller.apply(starting)
        #expect(host.calls == [.begin(starting)])
        controller.apply(listening)
        controller.apply(listening)
        listening.birdsHeard = 1
        controller.apply(listening)
        #expect(host.calls.count == 3)
        controller.apply(ended)
        #expect(host.calls.last == .end(ended))
        controller.apply(ended)
        controller.apply(.idle)
        #expect(host.calls.count == 4, "nothing stale: it ended once")
        controller.apply(starting)
        #expect(host.calls.last == .begin(starting))
    }

    @Test("refused an activity, as behind a locked phone, the next change of the run asks again")
    func refusedAsksAgain() {
        let host = FakeHost()
        host.refuses = true
        let controller = RunActivityController(host: host)
        var snapshot = RunSnapshot(phase: .listening, startedAt: .now, birdsHeard: 0, newPatchesWaiting: 0)
        controller.apply(snapshot)
        controller.apply(.idle)
        #expect(host.calls.count == 1, "a run that ended with none has nothing to end")

        controller.apply(snapshot)
        host.refuses = false
        snapshot.birdsHeard = 1
        controller.apply(snapshot)
        #expect(host.calls.last == .begin(snapshot))
        snapshot.birdsHeard = 2
        controller.apply(snapshot)
        #expect(host.calls.last == .update(snapshot))
    }

    @Test("over a real run: an add takes a bird off what's waiting, undo puts it back, and Stop through the intent ends the run and its activity")
    func overARealRun() async throws {
        let harness = try ListeningCoordinatorTests.makeHarness()
        let run = harness.run
        let store = CollectionStore(container: harness.album, sets: { [] })
        let host = FakeHost()
        let controller = RunActivityController(host: host)
        controller.follow { run.snapshot(in: store.collection) }
        #expect(host.calls == [.leftovers], "a launch clears what a killed app left, and starts nothing")

        await run.start()
        harness.source.feed(seconds: 4.5)
        try await waitUntil("candidates appear") { run.candidates.count == 2 }
        try await waitUntil("the activity follows") {
            if case .update(let shown)? = host.calls.last { return shown.birdsHeard == 2 && shown.newPatchesWaiting == 2 }
            return false
        }
        if case .begin? = host.calls.dropFirst().first {} else {
            Issue.record("the run's first call wasn't begin: \(host.calls)")
        }

        let addition = try #require(await run.add(run.candidates[0]))
        try await waitUntil("the add reaches it") {
            if case .update(let shown)? = host.calls.last { return shown.newPatchesWaiting == 1 }
            return false
        }
        run.undo(addition)
        try await waitUntil("the undo reaches it") {
            if case .update(let shown)? = host.calls.last { return shown.newPatchesWaiting == 2 }
            return false
        }

        RunStopper.stop = { await run.stop() }
        defer { RunStopper.stop = nil }
        _ = try await StopRunIntent().perform()
        #expect(run.state == .ended(.stopped))
        #expect(run.isReviewing, "the recap waits for the birder's return")
        try await waitUntil("the activity ends with the run") {
            if case .end? = host.calls.last { return true }
            return false
        }
    }

    @Test("the widget extension's copies of the app's colours are the app's")
    func inks() throws {
        func hex(_ color: Color, _ style: UIUserInterfaceStyle, _ contrast: UIAccessibilityContrast) -> [Int] {
            let traits = UITraitCollection { $0.userInterfaceStyle = style; $0.accessibilityContrast = contrast }
            var (r, g, b, a) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
            UIColor(color).resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
            return [r, g, b].map { Int(($0 * 255).rounded()) }
        }
        for (style, scheme) in [(UIUserInterfaceStyle.dark, ColorScheme.dark), (.light, .light)] {
            for (traitContrast, contrast) in [(UIAccessibilityContrast.normal, ColorSchemeContrast.standard), (.high, .increased)] {
                #expect(hex(GlanceInk.ink(scheme, contrast), style, traitContrast) == hex(.ink, style, traitContrast))
                #expect(hex(GlanceInk.secondary(scheme, contrast), style, traitContrast) == hex(.inkSecondary, style, traitContrast))
                #expect(hex(GlanceInk.rule(scheme, contrast), style, traitContrast) == hex(.rule, style, traitContrast))
            }
            #expect(hex(GlanceInk.page(scheme), style, .normal) == hex(.paper, style, .normal))
            for setID in ["us-ca-la", "us-ca-sd", "us-ca-bay", "us-ca-desert", "us-fl-orlando"] {
                #expect(hex(GlanceInk.tint(setID: setID, scheme, .standard), style, .normal) == hex(PatchEdition.tint(setID: setID), style, .normal), "\(setID)")
            }
        }
    }
}

@Suite("The widget snapshot")
@MainActor
struct WidgetSnapshotTests {
    private static let griffith = Coordinate(latitude: 34.1365, longitude: -118.2942, accuracy: 15)
    private static let finch = "Haemorhous mexicanus_House Finch"
    private static let jay = "Aphelocoma californica_California Scrub-Jay"
    private static let la = CardSet(id: "us-ca-la", name: "Los Angeles", edition: "Citrus edition", species: ["Haemorhous mexicanus", "Aphelocoma californica", "Sayornis nigricans"], regions: [southernCalifornia])

    private func snapshot(_ entries: [CardCollection.Entry], local: String? = "us-ca-la", painted: Bool = true) -> WidgetSnapshot {
        WidgetSnapshot(collection: CardCollection(entries, sets: [Self.la]), localSetID: local, name: { String($0.speciesID.drop { $0 != "_" }.dropFirst()) }, hasPainting: { _ in painted })
    }

    private func entry(_ species: String, at seconds: Double, location: Coordinate? = griffith) -> CardCollection.Entry {
        .init(identifier: UUID(), speciesID: species, confirmedAt: Date(timeIntervalSince1970: seconds), location: location)
    }

    @Test("before the first patch it has the local set's progress and nothing to open")
    func empty() {
        let value = snapshot([])
        #expect(value.latest == nil)
        #expect(value.progress?.sewnText == "0 of 3 sewn")
        #expect(value.spokenText == "Your first patch is a bird away. 0 of 3 sewn")
    }

    @Test("it's the most recently sewn patch, not the newest sighting, with its set's progress")
    func latest() {
        let value = snapshot([entry(Self.finch, at: 100), entry(Self.jay, at: 200), entry(Self.finch, at: 300)])
        #expect(value.latest?.name == "California Scrub-Jay")
        #expect(value.latest?.setName == "Los Angeles")
        #expect(value.latest?.link == PatchLink(speciesID: Self.jay, setID: "us-ca-la"))
        #expect(value.progress?.sewnText == "2 of 3 sewn")
        #expect(value.spokenText == "Latest patch, California Scrub-Jay, Los Angeles. 2 of 3 sewn")
    }

    @Test("an Uncharted patch shows with the local set's progress, and opens with no set")
    func uncharted() {
        let value = snapshot([entry(Self.finch, at: 100, location: nil)])
        #expect(value.latest?.setName == "Uncharted")
        #expect(value.latest?.link == PatchLink(speciesID: Self.finch, setID: nil))
        #expect(value.progress?.setID == "us-ca-la")
    }

    @Test("it's rewritten when the newest patch or the set's progress changes, and only the words when the picture still stands")
    func rewriteRule() {
        let one = snapshot([entry(Self.finch, at: 100)])
        let repeatSeen = snapshot([entry(Self.finch, at: 100), entry(Self.finch, at: 200)])
        let two = snapshot([entry(Self.finch, at: 100), entry(Self.jay, at: 200)])
        let unpainted = snapshot([entry(Self.finch, at: 100)], painted: false)
        let none = snapshot([])

        #expect(WidgetSnapshot.rewrite(from: nil, to: none, hasPatchImage: false) == .words, "a first launch: the empty widget's words")
        #expect(WidgetSnapshot.rewrite(from: nil, to: one, hasPatchImage: false) == .wordsAndPatch)
        #expect(WidgetSnapshot.rewrite(from: one, to: repeatSeen, hasPatchImage: true) == .nothing, "a repeat changes neither")
        #expect(WidgetSnapshot.rewrite(from: one, to: two, hasPatchImage: true) == .wordsAndPatch, "a new patch")
        #expect(WidgetSnapshot.rewrite(from: two, to: one, hasPatchImage: true) == .wordsAndPatch, "the newest undone")
        #expect(WidgetSnapshot.rewrite(from: unpainted, to: one, hasPatchImage: true) == .wordsAndPatch, "its pack arrived")
        #expect(WidgetSnapshot.rewrite(from: one, to: one, hasPatchImage: false) == .wordsAndPatch, "the picture went missing")
        #expect(WidgetSnapshot.rewrite(from: one, to: none, hasPatchImage: true) == .words, "the last patch unpicked")

        var moved = one
        moved.progress?.total = 200
        #expect(WidgetSnapshot.rewrite(from: one, to: moved, hasPatchImage: true) == .words, "only the set's progress moved")
    }

    @Test("a patch's link survives its URL, and nothing else the app is handed reads as one")
    func links() throws {
        let link = PatchLink(speciesID: "Haemorhous mexicanus_House Finch", setID: "us-ca-la")
        #expect(link.url.scheme == "birdjournal")
        #expect(PatchLink(url: link.url) == link)
        let uncharted = PatchLink(speciesID: "Corvus corax_Common Raven", setID: nil)
        #expect(PatchLink(url: uncharted.url) == uncharted)
        #expect(!link.url.absoluteString.contains(" "))

        for other in ["birdjournal://", "birdjournal://?metaWearablesAction=register", "birdjournal://patch", "birdjournal://patch?species=", "https://birdquest.matthewcelia.com/j/abc", "other://patch?species=x"] {
            #expect(PatchLink(url: try #require(URL(string: other))) == nil, "\(other)")
        }
    }

    @Test("the extension's pictures stay under what WidgetKit will archive, or the widget silently stays on its placeholder")
    func picturesFitAWidget() throws {
        // From the system's log for a small widget on an iPhone SE, the lowest iOS 27 runs on: "totalArea: 518400 > max[375161.6]".
        // A 17 Pro's is 1,069,415. Counted together, in case the system does.
        let limit = 375_161
        let catalog = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "BirdJournalWidgets/Assets.xcassets")
        let patch = Int(((LatestPatchPublisher.patchWidth + FlatPatch.room * 2) * LatestPatchPublisher.patchScale).rounded(.up))
        for name in ["MaterialFelt.imageset/felt.jpg", "MaterialLinen.imageset/linen.jpg"] {
            let source = try #require(CGImageSourceCreateWithURL(catalog.appending(path: name) as CFURL, nil))
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            let width = try #require(properties[kCGImagePropertyPixelWidth] as? Int)
            let height = try #require(properties[kCGImagePropertyPixelHeight] as? Int)
            #expect(width * height + patch * patch < limit, "\(name) is \(width)×\(height)")
        }
    }

    @Test("behind a locked phone a new patch goes up as its plain painting, cut to shape, and is lit once the app is in front")
    func lockedThenLit() async throws {
        let album = try AlbumSchema.makeContainer(inMemory: true)
        let library = PackLibrary.forApp()
        let collection = CollectionStore(container: album, sets: { library.cardSets })
        let store = WidgetStore(directory: URL.temporaryDirectory.appending(path: "widget-\(UUID().uuidString)", directoryHint: .isDirectory))
        var inFront = false
        let publisher = LatestPatchPublisher(store: store, collection: collection, packs: library, isInFront: { inFront })

        album.mainContext.insert(Sighting(speciesID: Self.finch, confirmedAt: .now, location: Self.griffith, soundConfidence: 0.9, source: .phone))
        try album.mainContext.save()
        await publisher.write()
        #expect(store.snapshot()?.latest?.name == "House Finch", "the widget has the bird with the app in the background")
        #expect(store.snapshot()?.latest?.hasPainting == false, "marked to be lit later")
        let plain = try #require(store.patchImage())
        let (bytes, width, height) = try ShareCardTests.rgba(try #require(UIImage(data: plain)))
        #expect(bytes[3] == 0, "the corner is clear")
        #expect(bytes[(height / 2 * width + width / 2) * 4 + 3] == 255, "the patch is solid")

        await publisher.write()
        #expect(store.patchImage() == plain, "still in the background: the same picture")

        inFront = true
        await publisher.write()
        #expect(store.snapshot()?.latest?.hasPainting == true)
        #expect(store.patchImage() != plain, "lit")
    }

    @Test("the store hands the extension what the app wrote, and the old picture goes with the last patch")
    func store() throws {
        let store = WidgetStore(directory: URL.temporaryDirectory.appending(path: "widget-\(UUID().uuidString)", directoryHint: .isDirectory))
        #expect(store.snapshot() == nil)
        #expect(!store.hasPatchImage)

        let one = snapshot([entry(Self.finch, at: 100)])
        try store.write(one, patchPNG: Data([1, 2, 3]))
        #expect(store.snapshot() == one)
        #expect(store.patchImage() == Data([1, 2, 3]))

        var words = one
        words.progress?.sewn = 2
        try store.write(words, patchPNG: nil)
        #expect(store.snapshot() == words)
        #expect(store.patchImage() == Data([1, 2, 3]), "only the words changed")

        try store.write(snapshot([]), patchPNG: nil)
        #expect(!store.hasPatchImage)
    }

    @Test("a picture that can't be drawn leaves the old words with the old picture and tries again; a blank drawn for a painting tries again too")
    func publisherNeverNamesTheWrongPicture() async throws {
        let album = try AlbumSchema.makeContainer(inMemory: true)
        let library = PackLibrary.forApp()
        let collection = CollectionStore(container: album, sets: { library.cardSets })
        let store = WidgetStore(directory: URL.temporaryDirectory.appending(path: "widget-\(UUID().uuidString)", directoryHint: .isDirectory))
        var drawing: LatestPatchPublisher.DrawnPatch? = .init(png: Data([1]), isLit: true)
        var drew = 0
        let publisher = LatestPatchPublisher(store: store, collection: collection, packs: library, draw: { _ in
            drew += 1
            return drawing
        })
        func add(_ species: String, at seconds: Double) throws {
            album.mainContext.insert(Sighting(speciesID: species, confirmedAt: Date(timeIntervalSince1970: seconds), location: Self.griffith, soundConfidence: 0.9, source: .phone))
            try album.mainContext.save()
        }

        try add(Self.finch, at: 100)
        await publisher.write()
        #expect(store.snapshot()?.latest?.name == "House Finch")

        drawing = nil
        try add(Self.jay, at: 200)
        await publisher.write()
        #expect(store.snapshot()?.latest?.name == "House Finch", "the finch's picture is still there, so its name stays")
        #expect(store.patchImage() == Data([1]))

        drawing = .init(png: Data([2]), isLit: false)
        await publisher.write()
        #expect(store.snapshot()?.latest?.link.speciesID == Self.jay)
        #expect(store.snapshot()?.latest?.hasPainting == false)
        let before = drew
        drawing = .init(png: Data([3]), isLit: true)
        await publisher.write()
        #expect(drew == before + 1, "the painting it couldn't decode gets another try")
        #expect(store.patchImage() == Data([3]))
        await publisher.write()
        #expect(drew == before + 1, "and then it stands")
    }

    @Test("from the album: an add writes a flat picture of the patch with clear corners, and a repeat leaves the files alone")
    func publisher() async throws {
        let album = try AlbumSchema.makeContainer(inMemory: true)
        let library = PackLibrary.forApp()
        let collection = CollectionStore(container: album, sets: { library.cardSets })
        let store = WidgetStore(directory: URL.temporaryDirectory.appending(path: "widget-\(UUID().uuidString)", directoryHint: .isDirectory))
        let publisher = LatestPatchPublisher(store: store, collection: collection, packs: library)

        await publisher.write()
        #expect(store.snapshot()?.latest == nil)
        #expect(store.snapshot()?.progress?.setID == "us-ca-la")
        #expect(!store.hasPatchImage)

        func add(_ species: String, at seconds: Double) throws {
            album.mainContext.insert(Sighting(speciesID: species, confirmedAt: Date(timeIntervalSince1970: seconds), location: Self.griffith, soundConfidence: 0.9, source: .phone))
            try album.mainContext.save()
        }

        try add(Self.finch, at: 100)
        await publisher.write()
        let written = try #require(store.snapshot())
        #expect(written.latest?.name == "House Finch")
        #expect(written.latest?.hasPainting == true)
        #expect(written.progress?.sewn == 1)

        let png = try #require(store.patchImage())
        let image = try #require(UIImage(data: png))
        let (bytes, width, height) = try ShareCardTests.rgba(image)
        #expect(width >= 440 && height >= 440, "sharp at a widget's size")
        #expect(width * height < 375_161 - 160_000, "and under what the smallest phone's widget can hold, with the felt")
        #expect(bytes[3] == 0, "the corner is clear: the patch sits on the widget's own felt")
        let middle = (height / 2 * width + width / 2) * 4
        #expect(bytes[middle + 3] == 255, "and the patch itself is solid")

        let attributes = try FileManager.default.attributesOfItem(atPath: store.directory.appending(path: "latest-patch.png").path(percentEncoded: false))
        try add(Self.finch, at: 200)
        await publisher.write()
        let after = try FileManager.default.attributesOfItem(atPath: store.directory.appending(path: "latest-patch.png").path(percentEncoded: false))
        #expect(attributes[.modificationDate] as? Date == after[.modificationDate] as? Date, "a repeat doesn't draw it again")
    }
}

@Suite("A run's clock and its end")
@MainActor
struct RunEndTests {
    @Test("time paused isn't time listened, finished or under way, and a clock reads it by starting later")
    func clock() {
        let start = Date(timeIntervalSince1970: 1_000)
        var clock = ListeningClock()
        #expect(clock.listened(from: start, to: start.addingTimeInterval(60)) == 60)
        #expect(clock.listened(from: nil, to: start) == 0)

        clock.note(isPaused: true, at: start.addingTimeInterval(60))
        clock.note(isPaused: true, at: start.addingTimeInterval(90))
        #expect(clock.pausedSince == start.addingTimeInterval(60), "the first of a pause's states starts it")
        #expect(clock.listened(from: start, to: start.addingTimeInterval(200)) == 60, "stopped during a pause, or read during one")

        clock.note(isPaused: false, at: start.addingTimeInterval(240))
        #expect(clock.pausedSince == nil)
        #expect(clock.listened(from: start, to: start.addingTimeInterval(300)) == 120)
        #expect(clock.shownStart(from: start) == start.addingTimeInterval(180))
    }

    @Test("a run that ends without Stop goes to its review, and the time stops there")
    func endsOnItsOwn() async throws {
        let harness = try ListeningCoordinatorTests.makeHarness()
        let run = harness.run
        await run.start()
        harness.source.feed(seconds: 4.5)
        try await waitUntil("candidates appear") { run.candidates.count == 2 }

        harness.source.giveOut()
        try await waitUntil("the run's own end reaches the review") { run.isReviewing }
        let ended = try #require(run.endedAt)
        #expect(!run.state.isActive)
        #expect(run.clockStoppedAt == ended)
        run.dismissEnded()
    }

    @Test("a bird added from a recap days old has the run's date and place, on the sighting and in what goes to a Guild")
    func addFromAnOldRecapKeepsTheRunsDate() async throws {
        let harness = try ListeningCoordinatorTests.makeHarness()
        let griffith = Coordinate(latitude: 34.1365, longitude: -118.2942, accuracy: 15)
        let started = Date.now.addingTimeInterval(-3 * 86_400)
        let ended = started.addingTimeInterval(1_800)
        let finch = Candidate(species: Species(index: 0, scientificName: "Haemorhous mexicanus", commonName: "House Finch", taxonomicClass: "Aves"), score: 0.9, windowsAboveThreshold: 2, firstHeardAt: 60, lastHeardAt: 120, admittedAt: 60)
        let waiting = EndedRun(source: "phone", startedAt: started, endedAt: ended, listened: 1_800, coordinate: griffith, birds: [.init(finch)], added: [])
        harness.defaults.set(try JSONEncoder().encode(waiting), forKey: ListeningCoordinator.endedRunKey)

        let run = harness.relaunched()
        try #require(run.isReviewing)
        try #require(await run.add(run.candidates[0]))

        let sighting = try #require(harness.stored.first)
        #expect(sighting.confirmedAt == ended)
        #expect(sighting.location == griffith)
        let input = FindOutbox.input(of: sighting, isNewPatch: true, packs: PackLibrary.forApp(), places: PlaceNames())
        let find = try #require(FindPolicy.find(for: input, sharing: .automatic))
        #expect(find.foundAt == FindPolicy.minute(ended))
        #expect(find.foundAt != FindPolicy.minute(.now))
    }

    @Test("killed with its review waiting, the next launch opens on it, with the birds, the place, the time and the adds; Done forgets it")
    func reviewOutlivesTheApp() async throws {
        let harness = try ListeningCoordinatorTests.makeHarness()
        let run = harness.run
        await run.start()
        harness.source.feed(seconds: 4.5)
        try await waitUntil("candidates appear") { run.candidates.count == 2 }
        let heard = run.candidates
        await run.stop()
        let addition = try #require(await run.add(run.candidates[0]))
        let (startedAt, endedAt, listened) = (run.startedAt, run.endedAt, run.listened)

        let again = harness.relaunched()
        #expect(again.isReviewing)
        #expect(again.state == .ended(.stopped))
        #expect(again.candidates == heard)
        #expect(again.startedAt == startedAt)
        #expect(again.endedAt == endedAt)
        #expect(abs(again.listened - listened) < 0.001)
        #expect(again.coordinate == run.coordinate)
        #expect(again.isAdded(heard[0]))
        #expect(!again.isAdded(heard[1]))

        // Still the real review: a skipped bird can be added, and an add from before can be undone.
        try #require(await again.add(again.candidates[1]))
        #expect(harness.stored.count == 2)
        again.undo(RunSightings.Addition(species: heard[0].species, sightingID: again.sightings.entries[0].id, identifier: addition.identifier, sewsPatch: true, patchCount: 1, placement: addition.placement))
        #expect(harness.stored.count == 1)

        let third = harness.relaunched()
        #expect(third.isAdded(heard[1]), "the adds made there are kept for the next launch too")
        #expect(!third.isAdded(heard[0]))
        third.dismissEnded()
        #expect(third.state == .idle)
        #expect(!harness.relaunched().isReviewing, "seen and done")
    }

}

@Suite("The run recap")
@MainActor
struct RunRecapTests {
    @Test("a bird's heard line is minutes ago, or the date on a recap that has waited past a day")
    func heardText() {
        let bird = Candidate(species: Species(index: 0, scientificName: "Haemorhous mexicanus", commonName: "House Finch", taxonomicClass: "Aves"), score: 0.9, windowsAboveThreshold: 2, firstHeardAt: 0, lastHeardAt: 0, admittedAt: 0)
        let text = { (seconds: TimeInterval) in
            CandidateRow.heardText(bird, startedAt: Self.start, now: Self.start.addingTimeInterval(seconds), calendar: Self.losAngeles, locale: Locale(identifier: "en_US"))
        }
        #expect(text(30) == "just now")
        #expect(text(180) == "3 min ago")
        #expect(text(3_700) == "1 h 1 min ago")
        #expect(text(86_399) == "23 h 59 min ago")
        #expect(text(86_400) == "Oct 26")
        #expect(text(3 * 86_400 + 60) == "Oct 26")
    }

    private static let start = Date(timeIntervalSince1970: 1_793_000_000)
    private static let losAngeles: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }()

    private func recap(minutes: Double = 42, place: String? = "Los Angeles", heard: Int = 3, patches: [String] = ["House Finch"]) -> RunRecap {
        RunRecap(startedAt: Self.start, listened: minutes * 60, place: place, birdsHeard: heard, patchNames: patches, calendar: Self.losAngeles, locale: Locale(identifier: "en_US"))
    }

    @Test("it says the date, the place, the time listened, the birds heard and the patches sewn, in plain words")
    func words() {
        let value = recap()
        #expect(value.dateText == "October 26, 2026")
        #expect(value.place == "Los Angeles")
        #expect(value.listenedText == "42 min")
        #expect(value.birdsLabel == "birds heard")
        #expect(value.patchesLabel == "patch sewn")
        #expect(value.spokenText == "October 26, 2026, Los Angeles. Listened for 42 minutes. 3 birds heard. 1 patch sewn: House Finch.")
        #expect(!value.spokenText.contains("·"))
    }

    @Test("small runs and long ones read properly")
    func amounts() {
        #expect(recap(minutes: 0.5).listenedText == "<1 min")
        #expect(recap(minutes: 0.5).listenedSpoken == "under a minute")
        #expect(recap(minutes: 1).listenedSpoken == "1 minute")
        #expect(recap(minutes: 60).listenedText == "1 hr")
        #expect(recap(minutes: 125).listenedText == "2 hr 5 min")
        #expect(recap(minutes: 125).listenedSpoken == "2 hours 5 minutes")
        #expect(recap(heard: 1).birdsLabel == "bird heard")
        #expect(recap(patches: []).patchesLabel == "patches sewn")
        #expect(recap(patches: []).spokenText.hasSuffix("0 patches sewn."))
        #expect(recap(patches: ["House Finch", "Black Phoebe"]).spokenText.hasSuffix("2 patches sewn: House Finch and Black Phoebe."))
        #expect(recap(place: nil).spokenText.hasPrefix("October 26, 2026. Listened"))
        #expect(recap(place: nil).title == "October 26, 2026")
        #expect(recap(place: FindPolicy.secretSpot).title == "A secret spot")
        #expect(recap().title == "Los Angeles")
    }

    @Test("the place follows the share policy: the city only, off when chosen, and a secret spot with a sensitive bird on it")
    func place() {
        let place = { (name: String?, hasLocation: Bool, pictured: [Bool?], city: Bool) in
            SharePolicy.recapPlace(placeName: name, hasLocation: hasLocation, pictured: pictured, includeCity: city)
        }
        #expect(place("Los Angeles, CA", true, [false], true) == "Los Angeles, CA")
        #expect(place("Los Angeles, CA", true, [], true) == "Los Angeles, CA", "nothing pictured, nothing to hide")
        #expect(place("Los Angeles, CA", true, [false], false) == nil, "the city off sends no place")
        #expect(place("Los Angeles, CA", true, [false, true], true) == FindPolicy.secretSpot, "a threatened bird is on it")
        #expect(place("Los Angeles, CA", true, [nil], true) == FindPolicy.secretSpot, "unrated counts as threatened")
        #expect(place("Los Angeles, CA", true, [true], false) == nil, "off still wins")
        #expect(place("34.1365° N, 118.2942° W", true, [false], true) == nil, "never a coordinate")
        #expect(place(nil, true, [false], true) == nil)
        #expect(place("Los Angeles", false, [true], true) == nil, "no fix, so no place at all")
    }

    @Test("what goes with the image credits the app and the patches' photos, and carries nothing the card doesn't")
    func shareText() {
        let text = recap().shareText(credits: ["© A. Birder (CC BY)"])
        #expect(text == "October 26, 2026, Los Angeles. Listened for 42 minutes, 3 birds heard, 1 patch sewn.\nHeard with Featherguild. Powered by BirdNET.\nPatches: AI illustrations from reference photos (© A. Birder (CC BY))")
        #expect(!recap(place: nil).shareText(credits: []).contains("Los Angeles"))
        #expect(!recap().shareText(credits: []).contains("AI illustrations"))
        #expect(RunRecap.imprint(hasPainting: false) == "Featherguild")
        #expect(!text.contains("·"), "the maintainer, 2026-11-06: no dots in what's shared")
        #expect(RunRecap.imprint(hasPainting: true) == "AI illustration, Featherguild")
        #expect(RunRecap.creditLine([]) == nil)
    }

    @Test("the image exports as a PNG with no Exif, GPS or TIFF metadata, at the share image's scale")
    func exportHasNoMetadata() throws {
        let image = RunRecapShareImage(recap: recap(), pictures: [], imprint: RunRecap.imprint(hasPainting: false), credits: nil)
        let rendered = try #require(CardExport.render(image, scale: CardExport.imageScale))
        let source = try #require(CGImageSourceCreateWithData(rendered.png as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect(properties[kCGImagePropertyTIFFDictionary] == nil)
        // ImageIO records the pixel size under Exif, as for the patch's image; nothing that dates or places it may be there.
        let exif = (properties[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
        #expect(exif[kCGImagePropertyExifDateTimeOriginal] == nil)
        #expect(exif[kCGImagePropertyExifDateTimeDigitized] == nil)
        #expect(rendered.image.size.width * rendered.image.scale == 1620)
    }

    @Test("Stop keeps the run's end, however long the review waits to be seen, and the ledger knows each sighting")
    func endedAt() async throws {
        let harness = try ListeningCoordinatorTests.makeHarness()
        let run = harness.run
        await run.start()
        #expect(run.endedAt == nil)
        harness.source.feed(seconds: 4.5)
        try await waitUntil("candidates appear") { run.candidates.count == 2 }
        let addition = try #require(await run.add(run.candidates[0]))
        #expect(run.sightings.entries.first?.identifier == addition.identifier)
        await run.stop()
        let ended = try #require(run.endedAt)
        #expect(ended >= (run.startedAt ?? .distantFuture))
        await run.start()
        #expect(run.endedAt == nil, "a new run starts its own clock")
        await run.stop()
    }
}
