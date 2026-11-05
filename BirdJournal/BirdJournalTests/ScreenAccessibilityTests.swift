import Album
import Foundation
import Identification
import Pack
import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import BirdJournal

// Issue #119, design guide page 16: VoiceOver over the finished screens. Listen, Collection, a card's page (only the
// readable face), the Atlas and a Guild's page are hosted with the app's shared objects (in memory, the fake account
// and Guild server, the seeded collection) in a window with app accessibility on, and their UIAccessibility tree is
// walked the way VoiceOver walks it (#52's method: XCUITest lists views SwiftUI hides from VoiceOver). Each screen is
// walked at the default text size and at the largest accessibility size, where every element must still be reachable.
// Every element VoiceOver lands on has a label, and none reads like a developer diagnostic.
@Suite("Screen accessibility", .serialized)
@MainActor
struct ScreenAccessibilityTests {
    /// The app's shared objects as `BirdJournalApp` wires them, in memory: the bundled pack, the seeded collection
    /// (#28's six sightings), the fake account signed in and the seeded fake Guild server.
    @MainActor
    final class Harness {
        let album: ModelContainer
        let frames: FrameStore
        let library: PackLibrary
        let edits: JournalEdits
        let account: AccountSession
        let circles: CircleStore
        let run: ListeningCoordinator
        let connection: GlassesConnection
        let sounds: ReferenceSounds
        let art: ArtJobs
        let outbox: FindOutbox
        let pushes: PushCenter
        let places = PlaceNames()

        /// - Parameters:
        ///   - index: what the phone last read of the pack index, so a set can be known before its pack is on the phone.
        ///   - session: what its downloads go through.
        init(seeded: Bool = true, index: PackIndex? = nil, session: URLSession = .shared) throws {
            album = try AlbumSchema.makeContainer(inMemory: true)
            frames = FrameStore(directory: URL.temporaryDirectory.appending(path: "ScreenAccessibility-\(UUID().uuidString)", directoryHint: .isDirectory))
            let storage = PackStorage(directory: URL.temporaryDirectory.appending(path: "ScreenAccessibilityPacks-\(UUID().uuidString)"))
            if let index { try storage.cacheIndex(index) }
            library = PackLibrary(bundled: try SpeciesPack.bundled(), storage: storage, indexURL: PackIndex.defaultURL, session: session, availableCapacity: { .max })
            edits = JournalEdits(container: album, frames: frames)
            account = FakeAccount.session(signedIn: true)
            let client = FakeCircleClient(seeded: true)
            circles = CircleStore(account: account, client: client, timeZone: { "America/Los_Angeles" })
            connection = GlassesConnection()
            let recorder = SightingRecorder(container: album, frames: frames, rarity: nil)
            let sightings = RunSightings(recorder: recorder)
            let phone = ListeningSession(
                loadEngine: { IdentificationEngine(model: ScriptedBirdModel(), occurrenceModel: SpyOccurrence()) },
                makeSource: { ManualAudioSource() },
                location: ScriptedLocationProvider([.denied])
            )
            let glasses = GlassesListeningSession(recorder: recorder, sightings: sightings, loadEngine: { IdentificationEngine(model: ScriptedBirdModel(), occurrenceModel: SpyOccurrence()) }, location: ScriptedLocationProvider([.denied]))
            run = ListeningCoordinator(phone: phone, glasses: glasses, sightings: sightings, levels: LevelSink(), defaultSource: .phone, defaults: UserDefaults(suiteName: "screen-ax-\(UUID().uuidString)")!)
            sounds = ReferenceSounds(player: MockSoundPlayer(), session: SpyPlaybackSession(), suppression: AudioSuppression(), phoneRunHoldsSession: { false })
            art = ArtJobs(account: account, client: nil, frames: frames, container: album)
            outbox = FindOutbox(account: account, client: client, fileURL: nil, sharing: { .automatic }, payload: { _, _ in nil })
            pushes = PushCenter(account: account, client: client, authorizer: FakeNotificationAuthorizer(permission: .authorized), defaults: UserDefaults(suiteName: "screen-ax-push-\(UUID().uuidString)")!, registerForRemoteNotifications: {})
            if seeded { DebugSeeds.seedJournal(context: album.mainContext, frames: frames) }
        }

        var newest: Sighting? { try? album.mainContext.fetch(Sighting.newestFirst()).first }

        /// `screen` on a navigation stack with the app's destinations and shared objects.
        func hosted(_ screen: some View, typeSize: DynamicTypeSize) -> some View {
            NavigationStack {
                screen.appDestinations()
            }
            .environment(connection)
            .environment(run)
            .environment(sounds)
            .environment(edits)
            .environment(account)
            .environment(circles)
            .environment(art)
            .environment(outbox)
            .environment(pushes)
            .environment(places)
            .environment(library)
            .environment(\.frameStore, frames)
            .environment(\.dynamicTypeSize, typeSize)
            .modelContainer(album)
        }
    }

    /// The labels VoiceOver reaches on `screen`, walked again until `ready` holds or fifteen seconds pass (SwiftUI fills
    /// the tree some time after the first render, later under a full parallel run). The window is a phone's width and tall
    /// enough that the lazy lists lay out what VoiceOver would scroll to.
    static func walk(_ screen: some View, harness: Harness, typeSize: DynamicTypeSize = .large, ready: ([String]) -> Bool) async throws -> [String] {
        CardFlipAccessibilityTests.enableAccessibility()
        let host = UIHostingController(rootView: harness.hosted(screen, typeSize: typeSize))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 2400)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        defer { window.isHidden = true }
        var labels: [String] = []
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(250))
            labels = Self.spoken(host.view)
            if ready(labels) { break }
        }
        return labels
    }

    /// What VoiceOver speaks for each element under `object`, skipping hidden subtrees: the label, else the value, else a
    /// text field's placeholder (a search field has no label; VoiceOver reads its prompt). An element with none of them
    /// is reported as "<unlabelled …>" with its type, traits and frame.
    static func spoken(_ object: Any) -> [String] {
        guard let object = object as? NSObject, !object.accessibilityElementsHidden else { return [] }
        if object.isAccessibilityElement {
            let words = [object.accessibilityLabel, object.accessibilityValue, (object as? UITextField)?.placeholder]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            return [words ?? "<unlabelled \(type(of: object)) traits \(object.accessibilityTraits.rawValue) at \(object.accessibilityFrame.integral)>"]
        }
        if let elements = object.accessibilityElements, !elements.isEmpty { return elements.flatMap(spoken) }
        let count = object.accessibilityElementCount()
        if count != NSNotFound, count > 0 { return (0..<count).compactMap { object.accessibilityElement(at: $0) }.flatMap(spoken) }
        if let view = object as? UIView { return view.subviews.flatMap(spoken) }
        return []
    }

    /// What every screen owes VoiceOver: no unlabelled element, and nothing that reads like a developer diagnostic.
    static func expectClean(_ labels: [String], screen: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(!labels.isEmpty, "\(screen): nothing reached", sourceLocation: sourceLocation)
        let unlabelled = labels.filter { $0.hasPrefix("<unlabelled") }
        #expect(unlabelled.isEmpty, "\(screen): \(unlabelled.count) unlabelled elements in \(labels)", sourceLocation: sourceLocation)
        let diagnostics = ["Developer", "DEBUG", "Optional(", "nil", "Error Domain", "persistentModelID", "UUID"]
        for label in labels {
            for word in diagnostics where label.contains(word) {
                Issue.record("\(screen): \"\(label)\" reads like a diagnostic (\(word))", sourceLocation: sourceLocation)
            }
        }
    }

    nonisolated static let sizes: [DynamicTypeSize] = [.large, .accessibility5]

    @Test("Listen: the source, Start listening and the local set; the cover is one labelled image", arguments: sizes)
    func listen(typeSize: DynamicTypeSize) async throws {
        let harness = try Harness()
        let labels = try await Self.walk(ListenView(), harness: harness, typeSize: typeSize) { labels in
            labels.contains("Start listening") && labels.contains("Your local set")
        }
        Self.expectClean(labels, screen: "Listen")
        #expect(labels.contains("Start listening"), "\(labels)")
        #expect(labels.contains("Settings"), "\(labels)")
        #expect(labels.contains { $0.hasPrefix("iPhone microphone") }, "the source row: \(labels)")
        #expect(labels.contains("Your local set"), "\(labels)")
        #expect(labels.contains { $0.contains("of 160 species collected") }, "the set's progress: \(labels)")
        let start = try #require(labels.firstIndex(of: "Start listening"))
        let local = try #require(labels.firstIndex(of: "Your local set"))
        #expect(start < local, "Start listening comes before the local set")
    }

    @Test("Collection: the summary, the modes and the patches, each with how often it was seen", arguments: sizes)
    func collection(typeSize: DynamicTypeSize) async throws {
        let harness = try Harness()
        let labels = try await Self.walk(JournalView(state: CollectionState()), harness: harness, typeSize: typeSize) { labels in
            labels.contains { $0.contains("House Finch") } && labels.contains("Patches")
        }
        Self.expectClean(labels, screen: "Collection")
        #expect(labels.contains { $0.hasSuffix("· 6 sightings") && $0.contains("patches") }, "the summary: \(labels)")
        for mode in ["Patches", "Sightings", "Species"] {
            #expect(labels.contains(mode), "\(mode): \(labels)")
        }
        #expect(labels.contains { $0.contains("House Finch") }, "\(labels)")
        #expect(labels.contains { $0.contains("edition patch, seen ") && $0.contains(", sewn ") }, "a patch in words: \(labels)")
        #expect(!labels.contains { $0.contains("not yet found") }, "a bird you haven't found has no patch: \(labels)")
        #expect(!labels.contains { $0.contains("Legendary") }, "no Legendary: \(labels)")
    }

    @Test("A patch's page: the patch in one sentence, its words in type, Turn over, and nothing of the paper card until it is turned", arguments: sizes)
    func patchPage(typeSize: DynamicTypeSize) async throws {
        let harness = try Harness()
        let phoebe = try #require(try harness.album.mainContext.fetch(Sighting.newestFirst()).first { $0.scientificName == "Sayornis nigricans" })
        let key = CardCollection.Patch.Key(speciesID: phoebe.speciesID, setID: PackIndex.bundledPackID)
        let labels = try await Self.walk(PatchDetailView(key: key), harness: harness, typeSize: typeSize) { labels in
            labels.contains("Turn over") && labels.contains { $0.hasPrefix("Black Phoebe, Citrus edition patch") }
        }
        Self.expectClean(labels, screen: "Patch page")
        #expect(labels.contains { $0.hasPrefix("Black Phoebe, Citrus edition patch, seen once, sewn ") }, "the patch in words: \(labels)")
        #expect(labels.contains("Black Phoebe"), "the name in type below it: \(labels)")
        #expect(labels.contains("Turn over"), "the visible action: \(labels)")
        #expect(!labels.contains { $0.hasPrefix("All ") && $0.contains("sighting") }, "the card stays hidden: \(labels)")
        #expect(!labels.contains { $0.hasPrefix("Wingspan") }, "the card stays hidden: \(labels)")
    }

    @Test("The paper card: the name, the story, the biology and the history, and nothing of the patch's face", arguments: sizes)
    func paperCard(typeSize: DynamicTypeSize) async throws {
        let harness = try Harness()
        let phoebe = try #require(try harness.album.mainContext.fetch(Sighting.newestFirst()).first { $0.scientificName == "Sayornis nigricans" })
        let key = CardCollection.Patch.Key(speciesID: phoebe.speciesID, setID: PackIndex.bundledPackID)
        let labels = try await Self.walk(PatchDetailView(key: key, startsTurned: true), harness: harness, typeSize: typeSize) { labels in
            labels.contains("Turn back") && labels.contains { $0.hasPrefix("All 1 sighting") }
        }
        Self.expectClean(labels, screen: "Paper card")
        #expect(labels.contains("Black Phoebe"), "the name: \(labels)")
        #expect(labels.contains("Sayornis nigricans"), "\(labels)")
        #expect(labels.contains { $0.hasPrefix("1 sighting here, sewn ") }, "the history: \(labels)")
        #expect(labels.contains { $0.hasPrefix("Wingspan") }, "the biology: \(labels)")
        #expect(labels.contains("Sources"), "\(labels)")
        #expect(labels.contains("AI illustration"), "\(labels)")
        #expect(!labels.contains { $0.hasPrefix("Black Phoebe, Citrus edition patch") }, "only the face showing: \(labels)")
        #expect(!labels.contains("Turn over"), "\(labels)")
    }

    @Test("The paper card's footer stays a few lines when it stacks: as the text grows, the card's room goes to the story", arguments: [DynamicTypeSize.xLarge, .xxLarge, .xxxLarge])
    func paperCardFooter(typeSize: DynamicTypeSize) async throws {
        let harness = try Harness()
        let phoebe = try #require(try harness.album.mainContext.fetch(Sighting.newestFirst()).first { $0.scientificName == "Sayornis nigricans" })
        let key = CardCollection.Patch.Key(speciesID: phoebe.speciesID, setID: PackIndex.bundledPackID)
        CardFlipAccessibilityTests.enableAccessibility()
        let host = UIHostingController(rootView: harness.hosted(PatchDetailView(key: key, startsTurned: true), typeSize: typeSize))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = try UIWindow(windowScene: #require(scene))
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        var all: NSObject?
        var sources: NSObject?
        for _ in 0..<60 where all == nil || sources == nil {
            try await Task.sleep(for: .milliseconds(250))
            all = SewingCeremonyAccessibilityTests.element(in: host.view, labelled: "All 1 sighting")
            sources = SewingCeremonyAccessibilityTests.element(in: host.view, labelled: "Sources")
        }
        let top = try #require(all).accessibilityFrame
        let bottom = try #require(sources).accessibilityFrame
        #expect(bottom.maxY - top.minY < 120, "the footer takes \(bottom.maxY - top.minY) points of a 470-point card")
    }

    @Test("An empty collection: the first patch in words and both ways on, with no patch and no pattern", arguments: sizes)
    func emptyCollection(typeSize: DynamicTypeSize) async throws {
        let harness = try Harness(seeded: false)
        let labels = try await Self.walk(JournalView(state: CollectionState()), harness: harness, typeSize: typeSize) { labels in
            labels.contains("Your first patch is a bird away.") && labels.contains("See the birds to find")
        }
        Self.expectClean(labels, screen: "Empty collection")
        let title = try #require(labels.firstIndex(of: "Your first patch is a bird away."), "\(labels)")
        let start = try #require(labels.firstIndex(of: "Start listening"), "\(labels)")
        let atlas = try #require(labels.firstIndex(of: "See the birds to find"), "\(labels)")
        #expect(title < start && start < atlas, "the words, then the first action, then the Atlas: \(labels)")
        #expect(!labels.contains { $0.contains(" patch,") }, "no patch: \(labels)")
    }

    @Test("Uncharted: its board says so, the patch reads Uncharted, and the card reads outside every set", arguments: sizes)
    func uncharted(typeSize: DynamicTypeSize) async throws {
        let harness = try Harness()
        let state = CollectionState()
        state.board = .uncharted
        let board = try await Self.walk(JournalView(state: state), harness: harness, typeSize: typeSize) { labels in
            labels.contains { $0.hasPrefix("Anna's Hummingbird, Uncharted patch") }
        }
        Self.expectClean(board, screen: "Uncharted board")
        #expect(board.contains { $0.hasPrefix("Anna's Hummingbird, Uncharted patch, seen once, sewn ") }, "\(board)")

        let hummingbird = try #require(try harness.album.mainContext.fetch(Sighting.newestFirst()).first { $0.scientificName == "Calypte anna" })
        let key = CardCollection.Patch.Key(speciesID: hummingbird.speciesID, setID: nil)
        let card = try await Self.walk(PatchDetailView(key: key, startsTurned: true), harness: harness, typeSize: typeSize) { labels in
            labels.contains("Turn back") && labels.contains("Uncharted, outside every set")
        }
        Self.expectClean(card, screen: "Uncharted card")
        #expect(card.contains("Uncharted, outside every set"), "\(card)")
        #expect(!card.contains("AI illustration"), "no painting to credit: \(card)")
    }

    // A set the phone knows from the index and whose pack it doesn't have: Coastal (a stand-in for San Diego, around the
    // seeded gallery's Balboa Park), with its download held open.

    private static let sanDiego = try! PackSet.decode(from: Data("""
    {"id": "us-ca-sd", "name": "San Diego", "edition": {"name": "Coastal edition", "theme": "Sea cliffs"}, "taxonomy": "IOC",
     "regions": [{"name": "SD", "source": "test", "polygons": [[[[-118, 32], [-116, 32], [-116, 34], [-118, 34], [-118, 32]]]]}],
     "species": [{"scientificName": "Haemorhous mexicanus", "commonName": "House Finch"}]}
    """.utf8))

    private static let sanDiegoPack = PackDescriptor(
        id: "us-ca-sd", name: "San Diego", version: 1, url: URL(string: "https://stalled.invalid/us-ca-sd.zip")!, sha256: "00", byteCount: 1, schemaVersion: 5, set: sanDiego
    )

    /// Never answers, so a download stays in flight until it's cancelled.
    private nonisolated final class StalledDownload: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {}
        override func stopLoading() {}
    }

    private static func sanDiegoHarness() throws -> Harness {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StalledDownload.self]
        let harness = try Harness(seeded: false, index: PackIndex(packs: [sanDiegoPack]), session: URLSession(configuration: configuration))
        DebugSeeds.seedGallery(context: harness.album.mainContext, frames: harness.frames)
        return harness
    }

    @Test("A patch whose pack isn't on the phone is a tagged blank; while the pack downloads it's being sewn, in words, and afterwards a blank again")
    func beingSewnOnTheRealPath() async throws {
        let harness = try Self.sanDiegoHarness()
        let state = CollectionState()
        state.board = .set(id: "us-ca-sd")
        let finch = "House Finch, Coastal edition patch, seen 6 times, sewn "
        #expect(harness.library.patchArtState(scientificName: "Haemorhous mexicanus", setID: "us-ca-sd") == .tagged)
        let waiting = try await Self.walk(JournalView(state: state), harness: harness) { $0.contains { $0.hasPrefix(finch) } }
        Self.expectClean(waiting, screen: "Board, pack not on the phone")
        #expect(waiting.contains { $0.hasPrefix(finch) && !$0.hasSuffix(", art on its way") }, "\(waiting)")

        harness.library.startDownload(Self.sanDiegoPack)
        for _ in 0..<40 where harness.library.patchArtState(scientificName: "Haemorhous mexicanus", setID: "us-ca-sd") != .beingSewn {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(harness.library.patchArtState(scientificName: "Haemorhous mexicanus", setID: "us-ca-sd") == .beingSewn)
        let sewing = try await Self.walk(JournalView(state: state), harness: harness) { $0.contains { $0.hasPrefix(finch) && $0.hasSuffix(", art on its way") } }
        Self.expectClean(sewing, screen: "Board, pack on its way")
        #expect(sewing.contains { $0.hasPrefix(finch) && $0.hasSuffix(", art on its way") }, "\(sewing)")
        let key = CardCollection.Patch.Key(speciesID: "Haemorhous mexicanus_House Finch", setID: "us-ca-sd")
        let page = try await Self.walk(PatchDetailView(key: key), harness: harness) { $0.contains("Turn over") }
        Self.expectClean(page, screen: "Page, pack on its way")
        #expect(page.contains { $0.hasPrefix(finch) && $0.hasSuffix(", art on its way") }, "\(page)")

        harness.library.cancelDownload(id: "us-ca-sd")
        for _ in 0..<40 where harness.library.patchArtState(scientificName: "Haemorhous mexicanus", setID: "us-ca-sd") != .tagged {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(harness.library.patchArtState(scientificName: "Haemorhous mexicanus", setID: "us-ca-sd") == .tagged, "a cancelled download leaves the tagged blank")
    }

    @Test("A bird's patches across places: each reads the bird's name, the blank of a set whose pack isn't on the phone too", arguments: sizes)
    func speciesPatches(typeSize: DynamicTypeSize) async throws {
        let harness = try Self.sanDiegoHarness()
        let labels = try await Self.walk(SpeciesPatchesView(scientificName: "Haemorhous mexicanus", commonName: "House Finch"), harness: harness, typeSize: typeSize) { labels in
            labels.contains { $0.hasPrefix("House Finch, Coastal edition patch") } && labels.contains("Open in Field Guide")
        }
        Self.expectClean(labels, screen: "Species patches")
        #expect(labels.contains { $0.hasPrefix("House Finch, Citrus edition patch, seen 9 times, sewn ") }, "\(labels)")
        #expect(labels.contains { $0.hasPrefix("House Finch, Coastal edition patch, seen 6 times, sewn ") }, "the blank: \(labels)")
        #expect(labels.contains("Open in Field Guide"), "\(labels)")
    }

    @Test("Not yet found: a set's silhouette rows have the number and name in words; the bird's page has its number and the way on", arguments: sizes)
    func notYetFound(typeSize: DynamicTypeSize) async throws {
        let harness = try Harness()
        let set = try #require(harness.library.sets.first { $0.id == PackIndex.bundledPackID })
        let first = try #require(set.species.first)
        let rows = try await Self.walk(SetView(id: set.id), harness: harness, typeSize: typeSize) { labels in
            labels.contains("001, \(first.commonName), not yet found here")
        }
        Self.expectClean(rows, screen: "Set page")
        #expect(rows.contains("001, \(first.commonName), not yet found here"), "\(rows)")

        let page = try await Self.walk(SpeciesPatchesView(scientificName: first.scientificName, commonName: first.commonName), harness: harness, typeSize: typeSize) { labels in
            labels.contains("Open in Field Guide") && labels.contains("Start listening")
        }
        Self.expectClean(page, screen: "A bird not yet found")
        #expect(page.contains("No sightings of \(first.commonName) yet"), "\(page)")
        #expect(page.contains("Number 1 of \(set.species.count) in \(set.name)"), "its number, in words: \(page)")
        #expect(page.contains("Open in Field Guide"), "the path to its Atlas profile: \(page)")
        #expect(!page.contains { $0.contains(" patch,") }, "no patch for a bird you haven't found: \(page)")
    }

    @Test("Atlas: the set's tile keeps Ready offline apart from the birder's progress, then the field guide", arguments: sizes)
    func atlas(typeSize: DynamicTypeSize) async throws {
        let harness = try Harness()
        let labels = try await Self.walk(FieldGuideView(), harness: harness, typeSize: typeSize) { labels in
            labels.contains { $0.contains("Los Angeles") } && labels.contains { $0.contains("Ready offline") }
        }
        Self.expectClean(labels, screen: "Atlas")
        #expect(labels.contains { $0.contains("Los Angeles") }, "\(labels)")
        #expect(labels.contains { $0.contains("Ready offline") }, "\(labels)")
        #expect(labels.contains { $0.contains("species collected") }, "\(labels)")
    }

    @Test("A Guild's page: the name and members first, Invite friends, the goal in words, the sharing setting in view", arguments: sizes)
    func guildPage(typeSize: DynamicTypeSize) async throws {
        let harness = try Harness()
        await harness.circles.refresh()
        let sunday = try #require(harness.circles.circles.first { $0.name == "Sunday Group" })
        let labels = try await Self.walk(CirclePageView(id: sunday.id), harness: harness, typeSize: typeSize) { labels in
            labels.contains { $0.contains("Invite friends") } && labels.contains { $0.contains("still to discover") }
        }
        Self.expectClean(labels, screen: "Guild page")
        let name = try #require(labels.firstIndex { $0.contains("Sunday Group") }, "\(labels)")
        let invite = try #require(labels.firstIndex { $0.contains("Invite friends") }, "\(labels)")
        #expect(name < invite, "the Guild leads, before Invite: \(labels)")
        #expect(labels.contains { $0.contains("members") }, "\(labels)")
        #expect(labels.contains { $0.contains("still to discover") }, "the goal in words: \(labels)")
        #expect(!labels.contains { $0.localizedCaseInsensitiveContains("days left") }, "no countdown: \(labels)")
    }
}
