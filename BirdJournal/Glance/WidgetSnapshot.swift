import Foundation

/// What the Home Screen widget shows (issue #150): a small value the app writes to the App Group, beside a flat picture of
/// the patch. The album stays where it is: the widget reads only this.
nonisolated struct WidgetSnapshot: Codable, Hashable, Sendable {
    struct Latest: Codable, Hashable, Sendable {
        /// The patch's species (a BirdNET label) and set, which is how the widget opens it.
        var link: PatchLink
        var name: String
        /// "Los Angeles", or "Uncharted" outside every set.
        var setName: String
        /// Whether the picture is its lit painting. Written as false for anything else, a blank or a plain painting drawn behind
        /// a locked phone, so the picture is drawn again whenever the phone has a painting to light.
        var hasPainting: Bool
    }

    struct SetCount: Codable, Hashable, Sendable {
        var setID: String
        var setName: String
        var sewn: Int
        var total: Int

        /// "3 of 160 sewn".
        var sewnText: String { "\(sewn) of \(total) sewn" }
    }

    /// The most recently sewn patch; nil before the first.
    var latest: Latest?
    /// The latest patch's set, or the birder's local set while there's none or it's Uncharted; nil when the phone knows no set.
    var progress: SetCount?

    /// The widget's kind, for reloading its timeline.
    static let widgetKind = "LatestPatch"

    /// What VoiceOver reads for the widget.
    var spokenText: String {
        let lead = latest.map { "Latest patch, \($0.name), \($0.setName)." } ?? Self.emptyText
        return progress.map { "\(lead) \($0.sewnText)" } ?? lead
    }

    /// What the widget says before the first patch, in the words of an empty collection.
    static let emptyText = "Your first patch is a bird away."

    /// How much of the widget's files a change means rewriting.
    enum Rewrite: Equatable, Sendable {
        case nothing
        case words
        case wordsAndPatch
    }

    /// The rule for when it's rewritten: nothing while the newest patch and the set's progress stand, the words when they
    /// move, and the picture too when the patch is a different one, its painting has come or isn't lit yet, or the picture is missing.
    static func rewrite(from old: WidgetSnapshot?, to new: WidgetSnapshot, hasPatchImage: Bool) -> Rewrite {
        if let latest = new.latest, latest.link != old?.latest?.link || latest.hasPainting != old?.latest?.hasPainting || !hasPatchImage {
            return .wordsAndPatch
        }
        return old == new ? .nothing : .words
    }
}

/// `birdjournal://patch?species=<BirdNET label>&set=<set id>`: a patch's page, from the widget. Outside every set there's no
/// `set`.
nonisolated struct PatchLink: Codable, Hashable, Sendable {
    var speciesID: String
    var setID: String?

    var url: URL {
        var components = URLComponents()
        components.scheme = "birdjournal"
        components.host = "patch"
        components.queryItems = [URLQueryItem(name: "species", value: speciesID)] + (setID.map { [URLQueryItem(name: "set", value: $0)] } ?? [])
        // A species and a set id always make a URL; `URLComponents` percent-encodes them.
        return components.url ?? URL(string: "birdjournal://patch")!
    }

    /// Nil for any other URL, which is the toolkit's or an invite's.
    init?(url: URL) {
        guard url.scheme == "birdjournal", url.host == "patch",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let species = items.first(where: { $0.name == "species" })?.value, !species.isEmpty
        else { return nil }
        speciesID = species
        setID = items.first { $0.name == "set" }?.value
    }

    init(speciesID: String, setID: String?) {
        self.speciesID = speciesID
        self.setID = setID
    }
}

/// The widget's two files in the App Group container: written by the app, read by the extension. A store over any folder, so
/// tests don't need the entitlement.
nonisolated struct WidgetStore: Sendable {
    static let appGroup = "group.com.matthewcelia.mybirdjournal"

    let directory: URL

    /// Nil where the App Group isn't provisioned: then the widget stays on its empty state and nothing else is affected.
    static var shared: WidgetStore? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup).map {
            WidgetStore(directory: $0.appending(path: "Widget", directoryHint: .isDirectory))
        }
    }

    private var snapshotURL: URL { directory.appending(path: "snapshot.json") }
    private var imageURL: URL { directory.appending(path: "latest-patch.png") }

    func snapshot() -> WidgetSnapshot? {
        (try? Data(contentsOf: snapshotURL)).flatMap { try? JSONDecoder().decode(WidgetSnapshot.self, from: $0) }
    }

    func patchImage() -> Data? {
        try? Data(contentsOf: imageURL)
    }

    var hasPatchImage: Bool {
        FileManager.default.fileExists(atPath: imageURL.path(percentEncoded: false))
    }

    /// Writes the snapshot, and the picture when there's a new one. The picture goes first, so a snapshot never names a patch
    /// its picture isn't of for longer than the two writes. With no latest patch the old picture goes.
    func write(_ snapshot: WidgetSnapshot, patchPNG: Data?) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let patchPNG {
            try patchPNG.write(to: imageURL, options: .atomic)
        } else if snapshot.latest == nil, hasPatchImage {
            try FileManager.default.removeItem(at: imageURL)
        }
        try JSONEncoder().encode(snapshot).write(to: snapshotURL, options: .atomic)
    }
}
