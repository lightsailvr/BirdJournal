#if DEBUG
import Album
import Foundation
import Identification
import Pack
import SwiftData
import SwiftUI
import UIKit

/// Launch flags for simulator screenshots and checks (issue #28), read once when the root appears:
///
/// - `-seedJournal YES` adds a few sightings with generated frames, spread over a kilometre of Griffith Park so the
///   map shows several pins (with `-inMemoryAlbum YES` nothing touches the album on disk).
/// - `-patchLight "x,y"` puts the patches' light somewhere, as a tilt would (issue #134's screenshots; the simulator has
///   no motion; "l0.5,u0.6" for left and up, since a launch argument can't start with a minus); `-patchLightSweep YES` circles it and logs frame times under the `patch-light` category.
/// - `-seedGallery YES` adds fifteen House Finch cards over three weeks, nine in Los Angeles and six in San Diego, for
///   the species' patches (issue #134).
/// - `-autoScreen <name>` opens a screen: `listen`, `listening` (starts a phone run; `-autoPhoneListening <wav>`
///   feeds that file), `review` (the first heard candidate), `journal` or `cards` (the Patches view), `sightings`,
///   `reveal` (the new-patch reveal of the newest seeded sighting, over the Listen tab; over a phone run with
///   `-autoPhoneListening <wav>`; `-autoCardSpecies` picks the species), `card` and `card-back` (the newest
///   card, front or back up, or with `-autoCardSpecies <scientific name>` that species' newest),
///   `species` or `gallery` (the patches of the newest sighting's species), `species-list` (the
///   Species view with its set progress), `set` (a set's page in the Field Guide: the bundled pack's, or
///   `-autoSet <id>`), `sighting` (the newest, or `-autoCardSpecies`'s), `map` (the newest sighting's full map), `share` ("A story to share" for the same sighting, issue #66), `guide`, `profile` (the Black Phoebe),
///   `packs`, `pack` (the bundled pack), `credits`, `settings`, `account` (Settings → Account; `-fakeAccount
///   signedOut|signedIn` fakes the sign-in), `support` (the tip jar; `-autoTipThanks YES` shows its
///   thank-you), `source` (the audio source sheet), and the Circle tab (issue #61; with `-fakeAccount
///   signedOut|signedIn` and `-fakeCircles empty|some`): `circles` (the tab: the sign-in invitation, no circles, or the
///   list), `circle` (the first circle's page), `compare` (Compare birds with its first friend), `circle-invite` (its invitation, QR code and link), `circle-goal` (its new-goal sheet, issue #65), `circle-new` (the
///   name sheet), `join` (the join screen for `-autoInvite <token>`, by default `fake-invite`; `expired` and `full`
///   show those refusals).
/// - `-autoArt pending|ready|failed` gives the newest seeded card with a glasses photo that scene art state (issue #68):
///   a job on its way, a painting (a warm wash over its photo), or a failed job. With `-fakeAccount signedIn` and
///   `-fakeArt paints|pending|fails` (the in-memory art server; `-fakeAccount` alone paints), Try again and Retry art
///   work too. `photo-preview` gives it photo art waiting beside its glasses photo (issue #69), `photo-approved`
///   approved photo art. `-fakeArtDaily <n>` keeps the public launch's allowance in the fake, and `-fakeLibraryPhoto`
///   makes "Choose from your library" pick the card's glasses photo as a library photo (the system picker is out of
///   the UI tests' reach). `-autoPhotoArt request|review` opens photo art's request or comparison sheet on the card.
/// - `-autoDownloadPack <id>` (with `-packIndexURL <url>`) opens the packs and downloads that pack.
/// - `-collectionIntroShown NO` shows the one-time "your collection so far" moment on every launch (the argument
///   domain overrides the remembered flag); `YES` keeps it away.
/// - `-reduceMotion YES` makes the card flip switch faces as with the system's Reduce Motion, which a UI test cannot
///   turn on.
/// - `-captionWriter fixed` writes every add's caption as a fixed line (`FixedCaptionWriter`), for simulators without
///   Apple Intelligence; `none` writes none, so the card shows the lore's tagline. The seeded Black Phoebe has a caption.
/// - `-autoLocation denied` with `-autoPhoneListening <wav>` answers the location request as denied instead of
///   prompting, for the UI tests.
/// - `-autoQuery <text>` searches the Collection or the Atlas once; `-autoThenTab <tab>` switches tab after the screen
///   opens; `-fakeGlasses unregistered|noneLinked|notConnected` gives the Listen page those glasses states;
///   `-fakeCircles offline` makes the Guilds unreachable; `-autoScrollTo guild-settings` scrolls a Guild's page to its
///   settings (issue #119's screenshots of the states).
/// - `-developer YES`, `-autoMockLens YES` and `-autoPhoneListening` alone open the developer hub, whose own flags
///   drive the lens and the raw listening screens.
struct DebugLaunch: ViewModifier {
    @Environment(\.modelContext) private var context
    @Environment(\.frameStore) private var frameStore
    @Environment(ListeningCoordinator.self) private var run
    @Environment(PackLibrary.self) private var library
    @Environment(CircleStore.self) private var circles
    @Binding var tab: RootView.Tab
    @Binding var journalMode: JournalView.Mode
    @Binding var listenPath: NavigationPath
    @Binding var journalPath: NavigationPath
    @Binding var guidePath: NavigationPath
    @Binding var circlesPath: NavigationPath
    @Binding var showingDeveloper: Bool

    func body(content: Content) -> some View {
        content.task {
            let defaults = UserDefaults.standard
            if defaults.bool(forKey: "seedJournal") { DebugSeeds.seedJournal(context: context, frames: frameStore) }
            if defaults.bool(forKey: "seedGallery") { DebugSeeds.seedGallery(context: context, frames: frameStore) }
            if let mode = defaults.string(forKey: "autoArt") { DebugSeeds.setArt(mode, context: context, frames: frameStore) }
            if let id = defaults.string(forKey: "autoDownloadPack") {
                tab = .guide
                guidePath.append(Route.packs)
                Task {
                    await library.refreshIndex()
                    if let descriptor = library.index?.descriptor(id: id) { library.startDownload(descriptor) }
                }
                return
            }
            if DeveloperView.isRequestedAtLaunch, defaults.string(forKey: "autoScreen") == nil {
                showingDeveloper = true
                return
            }
            guard let screen = defaults.string(forKey: "autoScreen") else { return }
            switch screen {
            case "listen":
                tab = .listen
            case "listening", "review":
                tab = .listen
                run.source = .phone
                await run.start()
                if screen == "review" {
                    // The WAV's first admissions take a few windows; wait for a bird the packs describe, so the
                    // review shows a photo, else take the first.
                    for _ in 0..<120 where !run.candidates.contains(where: { library.species(scientificName: $0.species.scientificName) != nil }) {
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                    run.reviewing = run.candidates.first { library.species(scientificName: $0.species.scientificName) != nil } ?? run.candidates.first
                }
            case "journal", "cards":
                tab = .journal
                journalMode = .cards
            case "sightings":
                tab = .journal
                journalMode = .sightings
            case "reveal":
                tab = .listen
                // With `-autoPhoneListening`, over a run, as after a real add (issue #117's screenshots).
                if defaults.string(forKey: "autoPhoneListening") != nil {
                    run.source = .phone
                    await run.start()
                }
                let species = defaults.string(forKey: "autoCardSpecies")
                let all = (try? context.fetch(Sighting.newestFirst())) ?? []
                if let newest = all.first(where: { species == nil || $0.scientificName == species }) {
                    run.showRevealForScreenshot(of: newest, placement: library.collection(of: all).placement(of: newest.identifier) ?? .uncharted)
                }
            case "card", "card-back":
                tab = .journal
                journalMode = .cards
                let species = defaults.string(forKey: "autoCardSpecies")
                let all = (try? context.fetch(Sighting.newestFirst())) ?? []
                if let newest = all.first(where: { species == nil || $0.scientificName == species }) {
                    let placement = library.collection(of: all).placement(of: newest.identifier)
                    journalPath.append(Route.patch(CardCollection.Patch.Key(speciesID: newest.speciesID, setID: placement?.setID)))
                }
                if screen == "card-back" { defaults.set(true, forKey: "autoCardBack") }
            case "species", "gallery":
                tab = .journal
                journalMode = .species
                if let newest = try? context.fetch(Sighting.newestFirst()).first {
                    journalPath.append(Route.speciesPatches(scientificName: newest.scientificName, commonName: library.commonName(for: newest)))
                }
            case "species-list":
                tab = .journal
                journalMode = .species
            case "set":
                tab = .guide
                guidePath.append(Route.set(id: defaults.string(forKey: "autoSet") ?? PackIndex.bundledPackID))
            case "sighting", "share", "map":
                tab = .journal
                let species = defaults.string(forKey: "autoCardSpecies")
                if let newest = (try? context.fetch(Sighting.newestFirst()))?.first(where: { species == nil || $0.scientificName == species }) {
                    journalPath.append(Route.sighting(newest.persistentModelID))
                }
                if screen == "share" { defaults.set(true, forKey: "autoShare") }
                if screen == "map" { defaults.set(true, forKey: "autoMap") }
            case "guide":
                tab = .guide
            case "profile":
                tab = .guide
                guidePath.append(Route.species(scientificName: "Sayornis nigricans", commonName: "Black Phoebe"))
            case "packs":
                tab = .guide
                guidePath.append(Route.packs)
            case "pack":
                tab = .guide
                guidePath.append(Route.packs)
                guidePath.append(Route.pack(id: PackIndex.bundledPackID))
            case "credits":
                tab = .listen
                listenPath.append(Route.settings)
                listenPath.append(Route.credits)
            case "settings":
                tab = .listen
                listenPath.append(Route.settings)
            case "account", "account-delete", "blocked":
                tab = .listen
                listenPath.append(Route.settings)
                listenPath.append(Route.account)
                // Issue #71: the deletion alert, and the blocked accounts.
                if screen == "account-delete" { defaults.set(true, forKey: "autoAccountDelete") }
                if screen == "blocked" { listenPath.append(Route.blockedAccounts) }
            case "support":
                tab = .listen
                listenPath.append(Route.settings)
                listenPath.append(Route.support)
            case "source":
                tab = .listen
                defaults.set(true, forKey: "autoSource")
            case "circles":
                tab = .circles
            case "circle", "circle-invite", "circle-goal", "circle-report":
                tab = .circles
                await circles.refresh()
                if let first = circles.circles.first {
                    if screen == "circle-invite" { defaults.set(true, forKey: "autoCircleInvite") }
                    if screen == "circle-report" { defaults.set(true, forKey: "autoCircleReport") }
                    if screen == "circle-goal" { defaults.set(true, forKey: "autoNewGoal") }
                    circlesPath.append(Route.circle(id: first.id))
                }
            case "compare":
                // Compare birds with the first circle's first friend (issue #64).
                tab = .circles
                await circles.refresh()
                if let first = circles.circles.first {
                    circlesPath.append(Route.circle(id: first.id))
                    try? await circles.loadDetail(id: first.id)
                    let me = circles.account.account?.id
                    if let friend = circles.details[first.id]?.members.first(where: { $0.id != me && $0.id != FakeCircleClient.me }) {
                        circlesPath.append(Route.compareBirds(friendID: friend.id, friendName: friend.name))
                    }
                }
            case "circle-new":
                tab = .circles
                defaults.set(true, forKey: "autoNewCircle")
            case "join":
                tab = .circles
                circles.pendingInvite = defaults.string(forKey: "autoInvite") ?? "fake-invite"
            default:
                break
            }
            // Issue #119: `-autoThenTab journal|guide|circles` switches tab once the screen is up, so a phone run's
            // listening accessory shows over another tab.
            if let next = defaults.string(forKey: "autoThenTab").flatMap(RootView.Tab.init(rawValue:)) {
                try? await Task.sleep(for: .seconds(1.5))
                tab = next
            }
        }
    }
}

/// Stands in for Core Location when a simulator run must not prompt (`-autoLocation denied`): the stream delivers a
/// denial and ends, so identification runs without the regional filter and the screen shows the no-location notice.
struct DeniedLocationProvider: LocationProvider {
    func fixes() -> AsyncStream<LocationFix> {
        AsyncStream { continuation in
            continuation.yield(.denied)
            continuation.finish()
        }
    }
}

/// Hands a file's chunks out at the pace they were recorded, so a WAV drives the Listen tab like a microphone would
/// instead of ending in a second.
final class PacedAudioSource: AudioSource {
    private let base: any AudioSource

    init(_ base: any AudioSource) {
        self.base = base
    }

    func start() async throws -> AsyncStream<AudioChunk> {
        let chunks = try await base.start()
        let (paced, continuation) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .unbounded)
        let forwarding = Task {
            for await chunk in chunks {
                try? await Task.sleep(for: .seconds(chunk.duration))
                guard !Task.isCancelled else { break }
                continuation.yield(chunk)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in forwarding.cancel() }
        return paced
    }

    func stop() async {
        await base.stop()
    }
}

/// A caption writer for simulator runs: always available, one fixed line naming the moment.
struct FixedCaptionWriter: CaptionWriter {
    static let versionString = "debug-fixed caption@1"
    let version = Self.versionString
    let isAvailable = true

    func caption(for request: CaptionRequest) async throws -> String {
        "\(request.moment.method == .heard ? "Heard" : "Seen") in the \(request.moment.timeOfDay.rawValue), the \(request.commonName) kept its old ways."
    }
}

enum DebugSeeds {
    /// Six sightings over nine days with generated frames (a ring at the centre of a 640 × 480 frame with a black
    /// border, so the 2x crop is visible as such), one with a note, three from the phone without a frame, two without
    /// a location. The located ones are spread over about a kilometre of Griffith Park, so the full map (issue #44)
    /// shows pins apart. The House Finch is there twice, so the Patches view shows its patch seen twice (the older
    /// heard from the phone, issue #132). The located ones carry the rarity the real geomodel
    /// gives them; the oldest, a Common Blackbird no pack describes, has no place, no rarity and no art (issue #52).
    static func seedJournal(context: ModelContext, frames: FrameStore?) {
        let bySidewalk = Coordinate(latitude: 34.1365, longitude: -118.2942, accuracy: 15)
        let byThePond = Coordinate(latitude: 34.1402, longitude: -118.2898, accuracy: 12)
        let byTheTrailhead = Coordinate(latitude: 34.1334, longitude: -118.2996, accuracy: 25)
        let seeds: [(label: String, minutesAgo: Double, location: Coordinate?, confidence: Double, source: SightingSource, frame: Bool, note: String?)] = [
            ("Haemorhous mexicanus_House Finch", 3, bySidewalk, 0.82, .glasses, true, nil),
            ("Sayornis nigricans_Black Phoebe", 9, byThePond, 0.77, .glasses, true, "Tail dipping over the pond, then off after a fly."),
            ("Zenaida macroura_Mourning Dove", 26 * 60, byTheTrailhead, 0.64, .phone, false, nil),
            ("Calypte anna_Anna's Hummingbird", 27 * 60, nil, 0.71, .glasses, true, nil),
            ("Haemorhous mexicanus_House Finch", 50 * 60, byTheTrailhead, 0.68, .phone, false, nil),
            ("Turdus merula_Common Blackbird", 9 * 24 * 60, nil, 0.58, .phone, false, nil),
        ]
        let rarity = BundledIdentification.rarityReader()
        for seed in seeds {
            let frame = seed.frame ? try? frames?.write(jpeg: frameJPEG()) : nil
            let sighting = Sighting(
                speciesID: seed.label,
                confirmedAt: Date.now.addingTimeInterval(-seed.minutesAgo * 60),
                location: seed.location,
                soundConfidence: seed.confidence,
                frameImagePath: frame,
                source: seed.source,
                note: seed.note
            )
            sighting.rarity = try? rarity?.snapshot(scientificName: sighting.scientificName, location: seed.location, at: sighting.confirmedAt)
            if seed.label.hasPrefix("Sayornis") {
                sighting.caption = CardCaption(text: "By the pond at morning, the dark sentinel kept its low perch.", generatorVersion: FixedCaptionWriter.versionString)
            }
            context.insert(sighting)
        }
        try? context.save()
    }

    /// The newest card with a glasses photo gets a scene art state for screenshots and the UI tests (issue #68).
    static func setArt(_ mode: String, context: ModelContext, frames: FrameStore?) {
        guard let sighting = (try? context.fetch(Sighting.newestFirst()))?.first(where: { $0.frameImagePath != nil }) else { return }
        switch mode {
        case "pending":
            sighting.art.startSceneJob(id: UUID())
        case "failed":
            let id = UUID()
            sighting.art.startSceneJob(id: id)
            sighting.art.sceneJobFailed(id: id)
        case "ready":
            guard let frames, let frame = sighting.frameImagePath, let photo = try? Data(contentsOf: frames.url(for: frame)),
                  let painting = FakeArtClient.paint(photo), let path = try? frames.write(jpeg: painting) else { return }
            let id = UUID()
            sighting.art.startSceneJob(id: id)
            sighting.art.sceneJobReady(id: id, path: path)
        case "photo-preview", "photo-approved":
            guard let frames, let frame = sighting.frameImagePath, let photo = try? Data(contentsOf: frames.url(for: frame)),
                  let painting = FakeArtClient.paint(photo), let path = try? frames.write(jpeg: painting) else { return }
            let id = UUID()
            sighting.art.startPhotoJob(id: id, source: frame)
            sighting.art.photoJobReady(id: id, path: path)
            if mode == "photo-approved" { sighting.art.approvePhotoArt() }
        default:
            return
        }
        try? context.save()
    }

    /// Fifteen House Finch sightings over three weeks for the species' patches (issue #53): nine around Griffith Park in Los
    /// Angeles and six in Balboa Park in San Diego, two of them on one day, some Seen, some with a glasses photo, each
    /// with the rarity the real geomodel gives it: a Los Angeles patch seen nine times and a San Diego one seen six.
    static func seedGallery(context: ModelContext, frames: FrameStore?) {
        let griffithPark = Coordinate(latitude: 34.1365, longitude: -118.2942, accuracy: 15)
        let balboaPark = Coordinate(latitude: 32.7341, longitude: -117.1446, accuracy: 15)
        let hoursAgo: [Double] = [2, 5, 26, 50, 74, 76, 120, 170, 200, 260, 300, 340, 410, 460, 500]
        let rarity = BundledIdentification.rarityReader()
        for (index, hours) in hoursAgo.enumerated() {
            let location = [3, 4, 5, 9, 10, 12].contains(index) ? balboaPark : griffithPark
            let frame = index.isMultiple(of: 3) ? try? frames?.write(jpeg: frameJPEG()) : nil
            let sighting = Sighting(
                speciesID: "Haemorhous mexicanus_House Finch",
                confirmedAt: Date.now.addingTimeInterval(-hours * 3600),
                location: location,
                soundConfidence: 0.7,
                frameImagePath: frame,
                source: frame == nil ? .phone : .glasses,
                method: index.isMultiple(of: 4) ? .seen : .heard
            )
            sighting.rarity = try? rarity?.snapshot(scientificName: sighting.scientificName, location: location, at: sighting.confirmedAt)
            context.insert(sighting)
        }
        try? context.save()
    }

    /// A stand-in camera frame at the glasses stream's portrait size (360 × 640, DECISIONS.md): a green field with
    /// a small ring at the centre.
    static func frameJPEG() -> Data {
        let size = CGSize(width: 360, height: 640)
        let image = UIGraphicsImageRenderer(size: size).image { renderer in
            UIColor(red: 0.35, green: 0.55, blue: 0.3, alpha: 1).setFill()
            renderer.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setStroke()
            let ring = UIBezierPath(ovalIn: CGRect(x: size.width / 2 - 24, y: size.height / 2 - 24, width: 48, height: 48))
            ring.lineWidth = 6
            ring.stroke()
            UIColor.black.setStroke()
            let border = UIBezierPath(rect: CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 8))
            border.lineWidth = 16
            border.stroke()
        }
        return image.jpegData(compressionQuality: 0.85) ?? Data()
    }
}
#endif
