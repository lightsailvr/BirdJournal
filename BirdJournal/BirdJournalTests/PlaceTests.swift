import Album
import CoreLocation
import Pack
import SwiftUI
import Testing
import UIKit
@testable import BirdJournal

/// The painting that follows you (issue #150): which set a place picks, what's remembered, and the read that never prompts.
@Suite("The place")
@MainActor
struct PlaceTests {
    nonisolated static func ring(_ corners: [(Double, Double)]) -> [CardSet.Point] {
        (corners + [corners[0]]).map { CardSet.Point(longitude: $0.0, latitude: $0.1) }
    }

    nonisolated static func set(_ id: String, _ corners: [(Double, Double)]) -> CardSet {
        CardSet(id: id, name: id, edition: "\(id) edition", species: ["Sayornis nigricans"], regions: [CardSet.Region(name: id, polygons: [[ring(corners)]])])
    }

    nonisolated static let losAngeles = set("us-ca-la", [(-119, 33.7), (-117.6, 33.7), (-117.6, 34.8), (-119, 34.8)])
    nonisolated static let desert = set("us-ca-desert", [(-117, 33), (-115, 33), (-115, 34.5), (-117, 34.5)])
    nonisolated static let griffith = Coordinate(latitude: 34.13, longitude: -118.29, accuracy: 10)
    nonisolated static let joshuaTree = Coordinate(latitude: 33.87, longitude: -115.90, accuracy: 10)
    nonisolated static let portland = Coordinate(latitude: 45.52, longitude: -122.68, accuracy: 10)

    struct Choice: Sendable {
        let because: String
        let coordinate: Coordinate?
        let newest: String?
        let sets: [CardSet]
        let shows: String?
    }

    nonisolated static let choices: [Choice] = [
        Choice(because: "the place's own set, over the newest sighting's", coordinate: joshuaTree, newest: "us-ca-la", sets: [losAngeles, desert], shows: "us-ca-desert"),
        Choice(because: "the place's own set, with no sightings", coordinate: joshuaTree, newest: nil, sets: [losAngeles, desert], shows: "us-ca-desert"),
        Choice(because: "the place's own set, though it isn't the bundled one", coordinate: griffith, newest: "us-ca-desert", sets: [desert, losAngeles], shows: "us-ca-la"),
        Choice(because: "outside every set, your last set", coordinate: portland, newest: "us-ca-desert", sets: [losAngeles, desert], shows: "us-ca-desert"),
        Choice(because: "outside every set with no sightings, the bundled set", coordinate: portland, newest: nil, sets: [desert, losAngeles], shows: "us-ca-la"),
        Choice(because: "no location, the newest sighting's set", coordinate: nil, newest: "us-ca-desert", sets: [losAngeles, desert], shows: "us-ca-desert"),
        Choice(because: "no location and no sightings, the bundled set", coordinate: nil, newest: nil, sets: [desert, losAngeles], shows: "us-ca-la"),
        Choice(because: "a sighting's set the phone no longer knows, the bundled set", coordinate: nil, newest: "us-ca-gone", sets: [desert, losAngeles], shows: "us-ca-la"),
        Choice(because: "no bundled set, the first the phone knows", coordinate: nil, newest: nil, sets: [desert], shows: "us-ca-desert"),
        Choice(because: "no sets at all, none", coordinate: joshuaTree, newest: "us-ca-la", sets: [], shows: nil),
    ]

    @Test("the fallback order: the set here, the newest sighting's, the bundled one", arguments: choices)
    func theFallbackOrder(_ choice: Choice) {
        #expect(LocalSet.choose(coordinate: choice.coordinate, newestSetID: choice.newest, sets: choice.sets, bundledID: "us-ca-la") == choice.shows, "\(choice.because)")
    }

    @Test("an Uncharted newest sighting doesn't lose your last set")
    func unchartedNewest() {
        let inSet = CardCollection.Entry(identifier: UUID(), speciesID: "Sayornis nigricans_Black Phoebe", confirmedAt: Date(timeIntervalSince1970: 1_000), location: Self.joshuaTree)
        let uncharted = CardCollection.Entry(identifier: UUID(), speciesID: "Sayornis nigricans_Black Phoebe", confirmedAt: Date(timeIntervalSince1970: 2_000), location: Self.portland)
        let collection = CardCollection([inSet, uncharted], sets: [Self.losAngeles, Self.desert])
        #expect(LocalSet.newestSetID(in: collection) == "us-ca-desert")
    }

    @Test("the read only ever uses a permission already granted", arguments: [
        (CLAuthorizationStatus.notDetermined, false), (.denied, false), (.restricted, false), (.authorizedWhenInUse, true), (.authorizedAlways, true),
    ] as [(status: CLAuthorizationStatus, reads: Bool)])
    func theReadNeverAsks(_ row: (status: CLAuthorizationStatus, reads: Bool)) {
        #expect(CoreLocationProvider.mayRead(row.status) == row.reads)
    }

    // MARK: - What's remembered

    struct Place: LocationProvider {
        let coordinate: Coordinate?
        func fixes() -> AsyncStream<LocationFix> { AsyncStream { $0.finish() } }
        func lastKnownCoordinate() -> Coordinate? { coordinate }
    }

    /// The bundled pack, and an index that knows the desert set, with the set's real boundary from the pack builder's definition.
    static func library() throws -> PackLibrary {
        let definition = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "packbuilder/packs/us-ca-desert/set.json")
        let storage = PackStorage(directory: URL.temporaryDirectory.appending(path: "PlaceTests-\(UUID().uuidString)"))
        let set = try PackSet.decode(from: Data(contentsOf: definition))
        try storage.cacheIndex(PackIndex(packs: [PackDescriptor(id: set.id, name: set.name, version: 1, url: URL(string: "https://example.com/desert.zip")!, sha256: "ab", byteCount: 1, set: set)]))
        return PackLibrary(bundled: try SpeciesPack.bundled(), storage: storage, availableCapacity: { .max })
    }

    static func defaults(name: String = "place-\(UUID().uuidString)") -> UserDefaults {
        UserDefaults(suiteName: name)!
    }

    static func place(_ library: PackLibrary, at coordinate: Coordinate?, defaults: UserDefaults) -> CurrentPlace {
        CurrentPlace(library: library, collection: { CardCollection([], sets: library.cardSets) }, location: Place(coordinate: coordinate), defaults: defaults)
    }

    @Test("a first launch is on the bundled set with its painting at once, then a read moves it and remembers only the set")
    func movesAndRemembers() async throws {
        let library = try Self.library()
        let suite = "place-\(UUID().uuidString)"
        let defaults = Self.defaults(name: suite)
        let place = Self.place(library, at: Self.joshuaTree, defaults: defaults)
        #expect(place.setID == "us-ca-la")
        #expect(place.painting != nil, "before anything's been awaited")
        let first = place.painting

        await place.refresh()

        #expect(place.setID == "us-ca-desert")
        #expect(place.painting != nil && place.painting !== first, "a cover that isn't on the phone as a pack, at full size")
        #expect(place.painting?.size == CGSize(width: 1536, height: 864))
        #expect(defaults.string(forKey: CurrentPlace.rememberedKey) == "us-ca-desert")
        #expect(defaults.persistentDomain(forName: suite)?.keys.sorted() == [CurrentPlace.rememberedKey], "the set, and no coordinate")
    }

    @Test("the next launch shows the remembered painting at once, and changes only when a read says so")
    func remembered() async throws {
        let library = try Self.library()
        let defaults = Self.defaults()
        await Self.place(library, at: Self.joshuaTree, defaults: defaults).refresh()

        let noFix = Self.place(library, at: Self.joshuaTree, defaults: defaults)
        #expect(noFix.setID == "us-ca-desert", "the first frame")
        #expect(noFix.painting?.size == CGSize(width: 1536, height: 864))

        let backInLA = Self.place(library, at: Self.griffith, defaults: defaults)
        #expect(backInLA.setID == "us-ca-desert", "the last place, until the read")
        await backInLA.refresh()
        #expect(backInLA.setID == "us-ca-la")
        #expect(defaults.string(forKey: CurrentPlace.rememberedKey) == "us-ca-la")
    }

    @Test("a remembered set the phone no longer knows is forgotten rather than shown")
    func forgotten() throws {
        let library = try Self.library()
        let defaults = Self.defaults()
        defaults.set("us-tx-gone", forKey: CurrentPlace.rememberedKey)
        #expect(Self.place(library, at: nil, defaults: defaults).setID == "us-ca-la")
    }

    @Test("with no location the read moves nothing, and asks nothing of the phone")
    func noLocation() async throws {
        let library = try Self.library()
        let defaults = Self.defaults()
        let place = Self.place(library, at: nil, defaults: defaults)
        let painting = place.painting
        await place.refresh()
        #expect(place.setID == "us-ca-la")
        #expect(place.painting === painting, "nothing decoded again")
    }

    // MARK: - The accent

    @Test("each set has its edition's thread; Uncharted has its own, and a set the app doesn't know keeps the aqua")
    func tints() {
        #expect(PatchEdition.tint(setID: "us-ca-la") == Color("EditionCitrus"))
        #expect(PatchEdition.tint(setID: "us-ca-sd") == Color("EditionCoastal"))
        #expect(PatchEdition.tint(setID: "us-ca-bay") == Color("EditionFog"))
        #expect(PatchEdition.tint(setID: "us-ca-desert") == Color("EditionDesert"))
        #expect(PatchEdition.tint(setID: "us-fl-orlando") == Color("EditionWetland"))
        #expect(PatchEdition.tint(setID: nil) == Color("EditionUncharted"))
        #expect(PatchEdition.tint(setID: "us-tx-houston") == .moss)
    }
}

/// The running stitch (issue #150).
@Suite("Thread progress")
@MainActor
struct ThreadProgressTests {
    @Test("a phone-wide row holds the mock's 24 stitches, and text sizes keep the proportion")
    func stitches() {
        #expect(ThreadProgress.stitches(width: 358) == 24)
        #expect(ThreadProgress.stitches(width: 358, height: 8) == 12)
        #expect(ThreadProgress.stitches(width: 0) == 1)
    }

    @Test("how many are sewn", arguments: [
        // value, total, sewn, counted birds
        (0.0, 160.0, 0, true), (1, 160, 1, true), (2, 160, 2, true), (3, 160, 2, true), (20, 160, 3, true), (80, 160, 12, true),
        (159, 160, 23, true), (160, 160, 24, true), (12, 14, 21, true), (14, 14, 24, true),
        (1, 1_000_000, 1, false), (2_000, 1_000_000, 1, false), (500_000, 1_000_000, 12, false), (999_999, 1_000_000, 23, false), (1_000_000, 1_000_000, 24, false),
        (5, 0, 0, true),
    ] as [(value: Double, total: Double, sewn: Int, counted: Bool)])
    func sewn(_ row: (value: Double, total: Double, sewn: Int, counted: Bool)) {
        #expect(ThreadProgress.sewn(value: row.value, total: row.total, stitches: 24, countsBirds: row.counted) == row.sewn, "\(row)")
    }

    /// The stitches actually drawn in `color`, along the row: a pixel fact.
    func drawn(_ thread: ThreadProgress, sized color: String, in variant: UITraitCollection, settle: Duration = .milliseconds(300)) async throws -> Int {
        let image = try await TokenPairingTests.renderImage(
            ZStack {
                Color.paper
                thread.frame(width: 358)
            },
            traits: variant, size: 360, settle: settle
        )
        return try stitches(in: image, colour: color, traits: variant)
    }

    /// How many of a phone-wide row's stitches are drawn in `colour`, across the middle of a 360 pt window.
    func stitches(in image: UIImage, colour: String, traits: UITraitCollection) throws -> Int {
        let target = try DesignTokenTests.color(colour, traits)
        var sewn = 0
        for stitch in 0..<24 {
            let x = 1 + (CGFloat(stitch) + 0.5) * (358 + 4) / 24 - 2
            let pixel = try #require(TokenPairingTests.pixel(image, at: CGPoint(x: x, y: 180)))
            if TokenPairingTests.distance(pixel, target) < 0.06 { sewn += 1 }
        }
        return sewn
    }

    @Test("rendered: the set's own thread, lavender for a goal, with a stitch for the first bird")
    func rendered() async throws {
        for (_, traits) in DesignTokenTests.variants {
            // Swift Testing runs suites side by side, and other screens show these sets: this asks for the memory of nothing.
            let one = ThreadProgress(value: 1, total: 160, sentence: "1 of 160", thread: .edition(setID: "us-ca-desert"))
            #expect(try await drawn(one, sized: "EditionDesert", in: traits) == 1)
            let half = ThreadProgress(value: 80, total: 160, sentence: "80 of 160", thread: .edition(setID: "us-ca-la"))
            #expect(try await drawn(half, sized: "EditionCitrus", in: traits) == 12)
            let downloading = ThreadProgress(value: 1, total: 2, sentence: "Downloading", thread: .edition(setID: "us-fl-orlando"))
            #expect(try await drawn(downloading, sized: "EditionWetland", in: traits) == 12, "the set being downloaded")
            let lavender = ThreadProgress(value: 12, total: 14, sentence: "12 of 14", thread: .together)
            #expect(try await drawn(lavender, sized: "ThreadTogether", in: traits) == 21)
        }
    }

    @Test("rendered: coming back to a set with more birds, the thread starts where it was and sews to the value")
    func sewsOnReturn() async throws {
        let traits = UITraitCollection(userInterfaceStyle: .dark)
        // A set no other test shows, in the aqua of a set the app doesn't know.
        let key = "set-us-test-return"
        let progress = SetProgress(setID: "us-test-return", name: "Somewhere", collected: 40, total: 160)
        ThreadProgress.lastSeen[key] = 1
        let host = Hosted(ThreadProgress(progress), traits: traits)
        defer { host.close() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(try stitches(in: host.image(), colour: "JournalMoss", traits: traits) == 1, "where it was")
        // However busy the other suites keep the main actor, it gets there.
        var sewn = 0
        for _ in 0..<40 where sewn != 6 {
            try await Task.sleep(for: .milliseconds(500))
            sewn = try stitches(in: host.image(), colour: "JournalMoss", traits: traits)
        }
        #expect(sewn == 6, "sewn")
        #expect(ThreadProgress.lastSeen[key] == 40, "so it sews once")
        #expect(try await drawn(ThreadProgress(progress), sized: "JournalMoss", in: traits, settle: .milliseconds(100)) == 6, "and comes back whole")
    }

    /// A thread on the page in a window of its own, left up to be looked at more than once.
    private final class Hosted {
        let window: UIWindow

        init(_ thread: ThreadProgress, traits: UITraitCollection) {
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
            window.frame = CGRect(x: 0, y: 0, width: 360, height: 360)
            window.windowLevel = .alert + 1
            window.overrideUserInterfaceStyle = traits.userInterfaceStyle
            window.rootViewController = UIHostingController(rootView: ZStack {
                Color.paper
                thread.frame(width: 358)
            }
            .ignoresSafeArea())
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
        }

        func image() -> UIImage {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.preferredRange = .standard
            return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
        }

        func close() {
            window.isHidden = true
        }
    }

    @Test("a rise it wasn't on screen for sews from the stitch it last showed; a fall, a first sight or Reduce Motion doesn't sew", arguments: [
        // last seen, now, starts at, still
        (Double?.some(1), 2.0, 1, false), (2, 40, 2, false), (nil, 40, 6, false), (40, 40, 6, false), (41, 40, 6, false), (1, 40, 6, true),
    ] as [(seen: Double?, value: Double, starts: Int, still: Bool)])
    func start(_ row: (seen: Double?, value: Double, starts: Int, still: Bool)) {
        #expect(ThreadProgress.startingStitches(lastSeen: row.seen, value: row.value, total: 160, stitches: 24, countsBirds: true, isStill: row.still) == row.starts, "\(row)")
    }
}
