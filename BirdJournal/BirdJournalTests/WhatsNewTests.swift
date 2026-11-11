import Foundation
import SwiftUI
import Testing
import UIKit
@testable import BirdJournal

@Suite("What's new")
@MainActor
struct WhatsNewTests {
    private static func release(_ version: String, items: Int = 2) -> ReleaseNotes.Release {
        ReleaseNotes.Release(
            version: version, date: "2026-11-11", headline: "A headline",
            items: (1...max(items, 1)).prefix(items).map { .init(title: "Change \($0)", detail: "What it means.", tryIt: $0 == 1 ? "Do this." : nil) },
            note: "Say what you found."
        )
    }

    private static func notes(_ versions: String...) -> ReleaseNotes {
        ReleaseNotes(releases: versions.map { release($0) })
    }

    private static func defaults() -> UserDefaults {
        UserDefaults(suiteName: "whats-new-\(UUID().uuidString)")!
    }

    // MARK: The bundled notes

    @Test("the bundled notes read, and their newest entry is this build's version")
    func bundledNotesMatchTheBuild() throws {
        let notes = try #require(ReleaseNotes.bundled(), "whats-new.json is missing from the app or doesn't decode")
        let latest = try #require(notes.latest)
        let version = try #require(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
        // `scripts/release.py prepare <version>` moves both together; a hand-bumped version has no card.
        #expect(latest.version == version, "the newest notes are for \(latest.version) and Version.xcconfig says \(version): run scripts/release.py prepare")
        #expect(!latest.items.isEmpty)
        #expect(Set(notes.releases.map(\.version)).count == notes.releases.count, "one entry per version")
    }

    @Test("an item decodes its optional try line from \"try\"")
    func decodesTryLine() throws {
        let json = #"{"releases":[{"version":"1.2.0","date":"2026-11-11","items":[{"title":"A","detail":"B","try":"C"},{"title":"D","detail":"E"}]}]}"#
        let notes = try JSONDecoder().decode(ReleaseNotes.self, from: Data(json.utf8))
        let release = try #require(notes.latest)
        #expect(release.items.map(\.tryIt) == ["C", nil])
        #expect(release.headline == nil && release.note == nil)
        #expect(release.items[0].spoken(number: 1) == "1. A. B Try it: C")
        #expect(release.items[1].spoken(number: 2) == "2. D. E")
    }

    // MARK: When it shows

    @Test("an update to a release with notes shows them once")
    func showsAfterAnUpdate() {
        let notes = Self.notes("0.2.0", "0.1.0")
        #expect(WhatsNewPolicy.releaseToShow(notes: notes, appVersion: "0.2.0", seen: "0.1.0", isFreshInstall: false)?.version == "0.2.0")
        #expect(WhatsNewPolicy.releaseToShow(notes: notes, appVersion: "0.2.0", seen: "0.2.0", isFreshInstall: false) == nil)
    }

    @Test("an install from before the card existed counts as an update; a fresh install doesn't")
    func freshInstallsAreNotUpdates() {
        let notes = Self.notes("0.2.0")
        #expect(WhatsNewPolicy.releaseToShow(notes: notes, appVersion: "0.2.0", seen: nil, isFreshInstall: false)?.version == "0.2.0")
        #expect(WhatsNewPolicy.releaseToShow(notes: notes, appVersion: "0.2.0", seen: nil, isFreshInstall: true) == nil)
    }

    @Test("notes for another version, no notes and empty notes show nothing")
    func staleNotesStayAway() {
        #expect(WhatsNewPolicy.releaseToShow(notes: Self.notes("0.2.0"), appVersion: "0.3.0", seen: "0.1.0", isFreshInstall: false) == nil)
        #expect(WhatsNewPolicy.releaseToShow(notes: nil, appVersion: "0.2.0", seen: "0.1.0", isFreshInstall: false) == nil)
        let empty = ReleaseNotes(releases: [Self.release("0.2.0", items: 0)])
        #expect(WhatsNewPolicy.releaseToShow(notes: empty, appVersion: "0.2.0", seen: "0.1.0", isFreshInstall: false) == nil)
    }

    @Test("a fresh install remembers the version it started at, so the next release has a card")
    func freshInstallRemembersItsVersion() {
        let defaults = Self.defaults()
        let first = WhatsNewCenter(notes: Self.notes("0.2.0"), appVersion: "0.2.0", defaults: defaults, isFreshInstall: true)
        #expect(first.pending == nil)
        #expect(defaults.string(forKey: WhatsNewCenter.seenKey) == "0.2.0")
        // The journal exists by now, and the update arrives.
        let updated = WhatsNewCenter(notes: Self.notes("0.3.0", "0.2.0"), appVersion: "0.3.0", defaults: defaults, isFreshInstall: false)
        #expect(updated.pending?.version == "0.3.0")
    }

    @Test("the card waits to be shown, and once shown it isn't shown again")
    func shownOnce() {
        let defaults = Self.defaults()
        defaults.set("0.1.0", forKey: WhatsNewCenter.seenKey)
        let center = WhatsNewCenter(notes: Self.notes("0.2.0", "0.1.0"), appVersion: "0.2.0", defaults: defaults, isFreshInstall: false)
        #expect(center.presented == nil)
        // Closed before the card came up: still waiting next time.
        #expect(defaults.string(forKey: WhatsNewCenter.seenKey) == "0.1.0")
        center.presentPending()
        #expect(center.presented?.version == "0.2.0" && center.pending == nil)
        #expect(defaults.string(forKey: WhatsNewCenter.seenKey) == "0.2.0")
        center.dismiss()
        #expect(center.presented == nil)
        center.presentPending()
        #expect(center.presented == nil)
        let next = WhatsNewCenter(notes: Self.notes("0.2.0", "0.1.0"), appVersion: "0.2.0", defaults: defaults, isFreshInstall: false)
        #expect(next.pending == nil)
    }

    @Test("Settings opens the newest notes any time, and nothing when the notes aren't this build's")
    func settingsOpensTheLatest() {
        let defaults = Self.defaults()
        defaults.set("0.2.0", forKey: WhatsNewCenter.seenKey)
        let center = WhatsNewCenter(notes: Self.notes("0.2.0"), appVersion: "0.2.0", defaults: defaults, isFreshInstall: false)
        #expect(center.pending == nil)
        center.open()
        #expect(center.presented?.version == "0.2.0")
        let stale = WhatsNewCenter(notes: Self.notes("0.2.0"), appVersion: "0.3.0", defaults: defaults, isFreshInstall: false)
        #expect(stale.latest == nil)
        stale.open()
        #expect(stale.presented == nil)
    }

    @Test("a debug build shows nothing unasked and remembers nothing, and `-whatsNew show` shows whatever was seen")
    func debugBuildsAsk() {
        let defaults = Self.defaults()
        defaults.set("0.1.0", forKey: WhatsNewCenter.seenKey)
        let quiet = WhatsNewCenter(notes: Self.notes("0.2.0"), appVersion: "0.2.0", defaults: defaults, isFreshInstall: false, showsUnasked: false)
        #expect(quiet.pending == nil && quiet.latest?.version == "0.2.0")
        #expect(defaults.string(forKey: WhatsNewCenter.seenKey) == "0.1.0")
        defaults.set("0.2.0", forKey: WhatsNewCenter.seenKey)
        let forced = WhatsNewCenter(notes: Self.notes("0.2.0"), appVersion: "0.2.0", defaults: defaults, isFreshInstall: false, showsUnasked: false, forced: true)
        #expect(forced.pending?.version == "0.2.0")
    }

    @Test("the fresh-install check looks where the journal is kept")
    func journalIsWhereTheCheckLooks() {
        // The test host is the app, which opened its album on disk before any test ran. If the album moves (another
        // configuration, another container), every update would look like a fresh install and no card would ever show.
        #expect(FileManager.default.fileExists(atPath: WhatsNewCenter.journalStoreURL.path), "no journal at \(WhatsNewCenter.journalStoreURL.path)")
    }

    // MARK: The card

    /// What VoiceOver reaches on the card, in order, walked as `ScreenAccessibilityTests` walks a screen: again until `ready`
    /// holds or ten seconds pass, since SwiftUI fills the tree some time after the first render, later under a full parallel run.
    private static func spoken(_ release: ReleaseNotes.Release, typeSize: DynamicTypeSize, ready: ([String]) -> Bool) async throws -> [String] {
        CardFlipAccessibilityTests.enableAccessibility()
        let card = WhatsNewCard(release: release) {}
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .environment(\.dynamicTypeSize, typeSize)
        let host = UIHostingController(rootView: card)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        defer { window.isHidden = true }
        var labels: [String] = []
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(250))
            labels = ScreenAccessibilityTests.spoken(host.view)
            if ready(labels) { break }
        }
        return labels
    }

    @Test("VoiceOver reads the card top to bottom: the edition, the title, each change as one stop, the note, the button", arguments: [DynamicTypeSize.large, .accessibility5])
    func voiceOverReadsTheCard(typeSize: DynamicTypeSize) async throws {
        let release = Self.release("0.2.0", items: 3)
        let labels = try await Self.spoken(release, typeSize: typeSize) { $0.count >= 8 }
        #expect(labels == [
            "Field notes, version 0.2.0",
            "What’s new",
            "A headline",
            "1. Change 1. What it means. Try it: Do this.",
            "2. Change 2. What it means.",
            "3. Change 3. What it means.",
            "Say what you found.",
            "Got it",
        ], "at \(typeSize): \(labels)")
    }

    @Test("a long release still ends in its button at the largest text size: the changes scroll, the button stays")
    func longReleaseKeepsItsButton() async throws {
        let labels = try await Self.spoken(Self.release("0.2.0", items: 6), typeSize: .accessibility5) { $0.contains("6. Change 6. What it means.") && $0.last == "Got it" }
        #expect(labels.last == "Got it", "\(labels)")
        #expect(labels.contains("6. Change 6. What it means."), "\(labels)")
    }
}
