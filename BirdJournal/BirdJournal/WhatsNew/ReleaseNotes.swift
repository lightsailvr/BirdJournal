import Foundation
import Observation
import OSLog
import SwiftData

/// What each release brought, in the birder's words: `whats-new.json` beside this file, newest first. `scripts/release.py`
/// checks it and the release steps in `docs/agents/release.md` add to it, one entry per merge of `dev` into `main`.
struct ReleaseNotes: Codable, Equatable, Sendable {
    struct Release: Codable, Equatable, Sendable, Identifiable {
        struct Item: Codable, Equatable, Sendable, Identifiable {
            /// A few words: what changed.
            let title: String
            /// A sentence or two on what it means for the birder.
            let detail: String
            /// What a tester might do to try it, if there's something to do.
            let tryIt: String?

            var id: String { title }

            enum CodingKeys: String, CodingKey {
                case title, detail
                case tryIt = "try"
            }

            /// One VoiceOver stop.
            func spoken(number: Int) -> String {
                ["\(number). \(title).", detail, tryIt.map { "Try it: \($0)" }].compactMap { $0 }.joined(separator: " ")
            }
        }

        /// The marketing version the entry describes, e.g. "0.2.0": `MARKETING_VERSION` in `Version.xcconfig`.
        let version: String
        /// The day it was struck, "2026-11-07".
        let date: String
        /// A line under the title, like a card's story title.
        let headline: String?
        let items: [Item]
        /// A closing line: how to say what you found.
        let note: String?

        var id: String { version }
    }

    let releases: [Release]

    var latest: Release? { releases.first }

    static let resource = "whats-new"

    /// The app's notes. A file that can't be read is a broken build, which the tests catch; the app goes on without the card.
    static func bundled(in bundle: Bundle = .main) -> ReleaseNotes? {
        guard let url = bundle.url(forResource: resource, withExtension: "json") else { return nil }
        do {
            return try JSONDecoder().decode(ReleaseNotes.self, from: Data(contentsOf: url))
        } catch {
            Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "whats-new").error("release notes unreadable: \(error.localizedDescription)")
            return nil
        }
    }
}

/// When the "What's new" card comes up by itself: once, the first time the app is opened after an update to a release that has notes.
enum WhatsNewPolicy {
    /// The release to show, if any.
    /// - Parameters:
    ///   - appVersion: this build's marketing version. Notes for another version say nothing about this build.
    ///   - seen: the version whose notes this iPhone last showed, or was installed at.
    ///   - isFreshInstall: nothing of the app was on this iPhone before this launch. To a new birder everything is new.
    static func releaseToShow(notes: ReleaseNotes?, appVersion: String, seen: String?, isFreshInstall: Bool) -> ReleaseNotes.Release? {
        guard let latest = notes?.latest, latest.version == appVersion, !latest.items.isEmpty else { return nil }
        if let seen { return seen == latest.version ? nil : latest }
        return isFreshInstall ? nil : latest
    }
}

/// The "What's new" card's state (the card is `WhatsNewCard`, over the tabs): the release waiting for the launch to settle, the
/// one on the card now, and what this iPhone has seen.
@MainActor @Observable
final class WhatsNewCenter {
    static let seenKey = "whatsNewSeenVersion"
    /// How long the page under it has to itself first, so the card is seen arriving.
    static let settle = Duration.milliseconds(700)

    /// The newest release with notes for this build: what Settings opens.
    let latest: ReleaseNotes.Release?
    /// Waiting for a moment with nothing else on the stage.
    private(set) var pending: ReleaseNotes.Release?
    /// On the card now.
    private(set) var presented: ReleaseNotes.Release?
    private let defaults: UserDefaults

    /// - Parameter showsUnasked: whether the card may come up by itself at all. Debug builds say no unless asked, so a test run
    ///   after a release doesn't find a card over every screen.
    init(notes: ReleaseNotes?, appVersion: String, defaults: UserDefaults = .standard, isFreshInstall: Bool, showsUnasked: Bool = true, forced: Bool = false) {
        self.defaults = defaults
        let current = notes?.latest.flatMap { $0.version == appVersion && !$0.items.isEmpty ? $0 : nil }
        latest = current
        if forced {
            pending = current
        } else if showsUnasked {
            pending = WhatsNewPolicy.releaseToShow(notes: notes, appVersion: appVersion, seen: defaults.string(forKey: Self.seenKey), isFreshInstall: isFreshInstall)
        }
        // A new birder, or a build with nothing to say: remembered now, so only a later release brings a card.
        if pending == nil, !forced, showsUnasked, let current { defaults.set(current.version, forKey: Self.seenKey) }
    }

    /// Where the album `AlbumSchema.makeContainer()` opens is kept: the same default configuration, asked for its place (the app
    /// group's container, since the widget has one). `WhatsNewTests` checks the journal really is there.
    static var journalStoreURL: URL { ModelConfiguration(isStoredInMemoryOnly: false).url }

    /// The app's own. Call it before anything else at launch: a fresh install is one with no journal on disk yet, and opening the
    /// album makes one.
    static func forApp() -> WhatsNewCenter {
        let journalExisted = FileManager.default.fileExists(atPath: journalStoreURL.path)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let asked = UserDefaults.standard.string(forKey: "whatsNew")
        #if DEBUG
        // `-whatsNew show` brings the card up at launch whatever has been seen; without it a debug build never shows it unasked.
        let showsUnasked = false
        let forced = asked == "show"
        #else
        // `-whatsNew hide` is for a UI test of the Release build, which has no other say over what its simulator has seen.
        let showsUnasked = asked != "hide"
        let forced = false
        #endif
        return WhatsNewCenter(notes: .bundled(), appVersion: version, isFreshInstall: !journalExisted, showsUnasked: showsUnasked, forced: forced)
    }

    /// Shows the waiting release, and remembers it: seen once is seen, even if the app is closed with the card still up.
    func presentPending() {
        guard let release = pending, presented == nil else { return }
        pending = nil
        show(release)
    }

    /// From Settings, any time.
    func open() {
        guard let latest else { return }
        pending = nil
        show(latest)
    }

    func dismiss() {
        presented = nil
    }

    private func show(_ release: ReleaseNotes.Release) {
        presented = release
        defaults.set(release.version, forKey: Self.seenKey)
    }
}
