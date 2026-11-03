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

        init(seeded: Bool = true) throws {
            album = try AlbumSchema.makeContainer(inMemory: true)
            frames = FrameStore(directory: URL.temporaryDirectory.appending(path: "ScreenAccessibility-\(UUID().uuidString)", directoryHint: .isDirectory))
            library = PackLibrary(bundled: try SpeciesPack.bundled(), storage: PackStorage(directory: URL.temporaryDirectory.appending(path: "ScreenAccessibilityPacks-\(UUID().uuidString)")), indexURL: PackIndex.defaultURL)
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

    @Test("Collection: the summary, the modes and the cards, Legendary said in words", arguments: sizes)
    func collection(typeSize: DynamicTypeSize) async throws {
        let harness = try Harness()
        let labels = try await Self.walk(JournalView(state: CollectionState()), harness: harness, typeSize: typeSize) { labels in
            labels.contains { $0.contains("House Finch") } && labels.contains("Cards")
        }
        Self.expectClean(labels, screen: "Collection")
        #expect(labels.contains { $0.hasPrefix("6 cards") }, "the summary: \(labels)")
        for mode in ["Cards", "Sightings", "Species"] {
            #expect(labels.contains(mode), "\(mode): \(labels)")
        }
        #expect(labels.contains { $0.contains("House Finch") }, "\(labels)")
        #expect(labels.contains { $0.contains("Legendary") }, "Legendary in words: \(labels)")
    }

    @Test("A card's page: the front's art, names and tale, and nothing of the back until it is turned", arguments: sizes)
    func cardPage(typeSize: DynamicTypeSize) async throws {
        let harness = try Harness()
        let phoebe = try #require(try harness.album.mainContext.fetch(Sighting.newestFirst()).first { $0.scientificName == "Sayornis nigricans" })
        let labels = try await Self.walk(CardDetailView(id: phoebe.persistentModelID), harness: harness, typeSize: typeSize) { labels in
            labels.contains { $0.hasPrefix("Card art") } && labels.contains { $0.hasPrefix("Black Phoebe") }
        }
        Self.expectClean(labels, screen: "Card page")
        #expect(labels.contains { $0.hasPrefix("Card art") }, "\(labels)")
        #expect(labels.contains { $0.hasPrefix("Black Phoebe") }, "\(labels)")
        #expect(labels.contains { $0.localizedCaseInsensitiveContains("flip") }, "the visible Flip action: \(labels)")
        #expect(!labels.contains("Encounter story"), "the back stays hidden: \(labels)")
        #expect(!labels.contains("Natural history"), "the back stays hidden: \(labels)")
        #expect(!labels.contains { $0.hasPrefix("Tagline:") }, "the back stays hidden: \(labels)")
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
