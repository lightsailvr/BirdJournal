#if DEBUG
import Album
import Foundation
import Identification
import LensSession
import MWDATCore
import MWDATInputs
import Pack
import SwiftData
import SwiftUI
import Synchronization
import UIKit

/// Launch flags for simulator screenshots and checks (issue #28), read once when the root appears:
///
/// - `-seedReferenceBirds YES` adds the five sightings the Compare reference says are yours (issue #150).
/// - `-seedJournal YES` adds a few sightings with generated frames, spread over a kilometre of Griffith Park so the
///   map shows several pins (with `-inMemoryAlbum YES` nothing touches the album on disk).
/// - `-patchLight "x,y"` puts the patches' light somewhere, as a tilt would (issue #134's screenshots; the simulator has
///   no motion; "l0.5,u0.6" for left and up, since a launch argument can't start with a minus); `-patchLightSweep YES` circles it and logs frame times under the `patch-light` category.
/// - `-fakeLibraryPhoto YES`: "Attach a photo" on a sighting hands over a generated picture instead of opening the system
///   picker, which XCUITest can't drive. The capture camera's library button does the same (issue #192), with a picture that
///   carries a date and a place of its own, 18 April 2026 in San Diego (`DebugSeeds.libraryPhotoJPEG`): a UI test can pick
///   in the real picker there (`LibraryCaptureUITests`), but doesn't know what a simulator's pictures carry.
/// - `-seedBoard YES` adds one sighting each of the bundled pack's first 30 birds in Griffith Park: a board that scrolls.
/// - `-seedLarge <n>` fills the album to n sightings over three years, for profiling (issue #150). With `-albumFile <name>` it
///   only writes the first time, so later launches read a full album off the disk. `-speedTour YES` then walks the screens and
///   prints what each cost (`SpeedTour`).
/// - `-seedNewestAt <place>` adds a sighting just now at one of `-autoLocation`'s places, so its set is the newest sighting's.
/// - `-seedGallery YES` adds fifteen House Finch cards over three weeks, nine in Los Angeles and six in San Diego, for
///   the species' patches (issue #134).
/// - `-autoScreen find` opens a find's page (`-autoFind <owner>/<sighting>`, by default Maya's Black Phoebe), and `circle-info` a
///   Guild's Info sheet (issue #150). `-fakeCircles one|shared|reference` seeds one Guild, finds in two, and the reference picture's.
/// - `-autoScreen <name>` opens a screen: `listen`, `listening` (starts a phone run; `-autoPhoneListening <wav>`
///   feeds that file), `review` (the first heard candidate), `journal` or `cards` (the Patches view), `sightings`,
///   `reveal` (the new-patch reveal of the newest seeded sighting, over the Listen tab; over a phone run with
///   `-autoPhoneListening <wav>`; `-autoCardSpecies` picks the species), `card` and `card-back` (the newest
///   card, front or back up, or with `-autoCardSpecies <scientific name>` that species' newest),
///   `species` or `gallery` (the patches of the newest sighting's species, or `-autoCardSpecies`'s, found or not), `species-list` (the
///   Species view with its set progress), `set` (a set's page in the Field Guide: the bundled pack's, or
///   `-autoSet <id>`), `sighting` (the newest, or `-autoCardSpecies`'s), `map` (the newest sighting's full map), `share` ("A story to share" for the same sighting, issue #66), `guide`, `profile` (the Black Phoebe, or `-autoCardSpecies`'s),
///   `packs`, `pack` (the bundled pack), `credits`, `settings`, `app-icon`, `account` (Settings → Account; `-fakeAccount
///   signedOut|signedIn` fakes the sign-in), `support` (the tip jar; `-autoTipThanks YES` shows its
///   thank-you), `source` (the audio source sheet), and the Circle tab (issue #61; with `-fakeAccount
///   signedOut|signedIn` and `-fakeCircles empty|some`): `circles` (the tab: the sign-in invitation, no circles, or the
///   list), `circle` (the first circle's page), `compare` (Compare birds with its first friend), `goal-patches` (every patch of its month), `circle-invite` (its invitation, QR code and link), `circle-goal` (its new-goal sheet, issue #65), `circle-new` (the
///   name sheet), `join` (the join screen for `-autoInvite <token>`, by default `fake-invite`; `expired` and `full`
///   show those refusals). `recap` ends a phone run on its recap, with `-autoRecapAdd YES` after adding the first bird the packs
///   describe. `-autoRunStopAfter <seconds>` runs a phone run behind whatever else is opened, and stops it then, as Stop on the Lock
///   Screen would. `glance` draws the Live Activity's and the widget's views in the app, since a screenshot can't reach them all.
/// - `-autoDownloadPack <id>` (with `-packIndexURL <url>`) opens the packs and downloads that pack.
/// - `-collectionIntroShown NO` shows the one-time "your collection so far" moment on every launch (the argument
///   domain overrides the remembered flag); `YES` keeps it away.
/// - `-hapticLog YES` lists the haptics played where a UI test can read them (`HapticLog`). `-resetLaunchSplash YES` forgets the
///   splash has played, and `-launchSplashSeconds <n>` holds it that long, so a UI test can catch it; `-modeFadeSeconds <n>` slows
///   the Collection's cross-fade between modes the same way (issue #150).
/// - `-acknowledgmentSeconds <n>` keeps an add's toast and Undo up that long.
/// - `-autoRevealDelay <n>` with `-autoScreen reveal` starts on the Collection tab and shows the page n seconds on, over whatever's been done
///   there by then (issue #150).
/// - `-coverRoomSeconds <n>` holds the room under a board after coming back from a patch's page, for a flick to try (issue #150).
/// - `-autoMapSpeciesPatches YES` with `-autoScreen map` goes on to the bird's patches in the map sheet's own stack (issue #150).
/// - `-reduceMotion YES` is the system's Reduce Motion for everything the app draws (`PatchMotion`): the card flip switches
///   faces, the stitch-in doesn't happen, the run's waveform holds still. The Lift doesn't read it: its cross-fade is the system's own, so it takes the real setting
///   (`simctl spawn <udid> defaults write com.apple.Accessibility ReduceMotionEnabled -bool true`, then relaunch). `-voiceOverPath YES` skips the stitch-in as VoiceOver does (issue #135).
/// - `-stitchInSeconds <n>` makes the stitch-in that long, so a UI test or a screenshot can catch it part way;
///   `-stitchInSweep YES` plays it round and round and logs frame times under the `stitch-in` category (issue #135).
/// - `-captionWriter fixed` writes every add's caption as a fixed line (`FixedCaptionWriter`), for simulators without
///   Apple Intelligence; `none` writes none, so the card shows the lore's tagline. The seeded Black Phoebe has a caption.
/// - `-autoLocation denied` answers the location request as denied instead of prompting, for the UI tests; `griffith` answers
///   with a fix in Griffith Park. `san-diego`, `oakland`, `joshua-tree` and `orlando` are places in the other sets, and `kansas`
///   is outside every set (`DebugPlace`). With `-autoPhoneListening <wav>` they answer a run, and at any launch the read that
///   picks the Listen painting (issue #150).
/// - `-freshPackStorage YES` starts with no downloads and no index read yet, as a fresh install does; with `-packIndexURL
///   http://127.0.0.1:9/index.json` the index stays out of reach (issue #150).
/// - `-fakeRunBirds "Haemorhous mexicanus_House Finch,…"` makes a run's list these BirdNET labels and hold still, the first
///   calling and the rest heard 3, 5, 7… minutes ago, so a tap can't land on a row that's just moved (issue #150). The run still
///   needs `-autoPhoneListening <wav>` for its waveform. `-autoRowAdd <name>` adds that bird as a row's button does, past its
///   reveal; `-fakeRunReorderEvery <seconds>` keeps those heard earlier swapping places, so the list keeps re-sorting;
///   `-fakeSheetDuringTouch YES` lands a review a second into a touch on the list; `-fakeLeaveDuringFlick YES` opens the
///   Collection while the list decelerates; `-autoRunStops YES` stops the run, for the review. `-patchDecodeLog YES` logs each patch decode under `patch-decode`.
/// - `-fakePatchArt missing|sewing` draws every patch without its painting: the blank with its paper tag, or "Being sewn"
///   in a set (issue #138). `-autoBoard uncharted` opens the Collection on the Uncharted board.
/// - `-autoQuery <text>` searches the Collection or the Atlas once; `-autoThenTab <tab>` switches tab after the screen
///   opens; `-fakeGlasses unregistered|noneLinked|notConnected` gives the Listen page those glasses states;
///   `-fakeCircles offline` makes the Guilds unreachable; `-fakeCircleLatency <seconds>` slows each of the fake's reads, and
///   `-circleCacheFile <name>` gives its store a cache in tmp to relaunch over (issue #150); `-autoScrollTo guild-settings` scrolls a Guild's page to its
///   settings (issue #119's screenshots of the states).
/// - `-autoScreen glasses-run` with `-autoGlassesListening <wav>` pairs the mock glasses and starts a real glasses run on the
///   Listen tab, the file standing in for the stream; `-autoLensAdd "House Finch,Dark-eyed Junco"` adds those birds on the
///   lens with mock inputs as they're heard, and `-autoLensBackInBackground YES` ends the run from the lens when the app
///   goes to the background (issue #135). `-albumFile <name>` keeps the album in a file of its own, for relaunching over it.
/// - `-fakeCamera ready|denied|unavailable` puts a stand-in behind "Capture a sighting" (issue #186: the simulator has no
///   camera, and a UI test can't answer the permission prompt): ready with a drawn viewfinder and a generated photo, or
///   refused, or with no camera to give (`-fakeCameraZoom 2.6` and `-fakeCameraFocus 0.3,0.4` open it zoomed and with focus
///   held there, issue #187). `-autoScreen capture` starts a phone run as `listening` does and opens the camera
///   over it; `-autoScreen name-bird` goes on to "Name this bird" with a stand-in photo, and `-autoQuery <text>` searches
///   there once. `-autoSeen "Calypte anna,Selasphorus sasin"` names a stand-in photo as each of those birds once the run is
///   on, past its reveal: rows under "Seen this run". `-autoUnnamed <n>` takes that many stand-in photos on the run and leaves
///   them unnamed (issue #188), before `-autoRunStops` ends it; `-seedSeen "Selasphorus sasin"` puts a sighting the birder
///   named of each of those birds in the album at launch, seen in Griffith Park in the last hours, and `-autoChangeBird YES`
///   opens "Change bird" on a sighting's page (issue #190); `-seedUnnamed <n>` puts that many in the album at launch, taken
///   in Griffith Park on earlier days, as earlier runs would have left them: the Collection's "To name".
/// - `-autoScreen idle-capture` opens the camera from the idle Listen tab, with no run (issue #191), and `idle-name-bird`
///   goes on to "Name this bird" with a stand-in photo taken there; `-autoLocation` says where the phone is. With
///   `-autoScreen listen`, `-autoIdleSeen "Calypte anna"` names a stand-in photo taken with no run as that bird, past its
///   reveal: the acknowledgment on the idle tab.
/// - `-autoLensCapture <n>` on a `glasses-run` takes that many photos from the lens's "Capture a sighting" (issue #193), by Mock
///   Device Kit's inputs, before `-autoLensAdd` adds its birds; `-autoGlassesCamera YES` gives that run's stand-in stream a
///   drawn camera frame, without which the lens has no picture to take. After each photo the lens asks for the bird's name
///   (issue #194): `-autoLensSay "annas humming bird"` has the mock's glasses hear that, and the first bird offered is
///   chosen; without it the photo is named later. `-autoGlassesMicrophone denied` takes the glasses' microphone
///   permission away once the run is on, so the lens never asks and the run's page offers to turn dictation on.
///   `-dictationSilenceSeconds <s>` is how long any lens listens for a first word (default 8),
///   `-dictationPauseSeconds <s>` how long words wait for more before they are matched (default 3), and
///   `-dictationKeepsStream NO` takes the camera stream off while it listens (`DictationSettings`).
/// - `-developer YES`, `-autoMockLens YES` and `-autoPhoneListening` alone open the developer hub, whose own flags
///   drive the lens and the raw listening screens.
struct DebugLaunch: ViewModifier {
    @Environment(\.modelContext) private var context
    @Environment(\.frameStore) private var frameStore
    @Environment(ListeningCoordinator.self) private var run
    @Environment(PackLibrary.self) private var library
    @Environment(CircleStore.self) private var circles
    @Environment(FindOutbox.self) private var findOutbox
    @Environment(GlassesConnection.self) private var connection
    @Environment(\.scenePhase) private var scenePhase
    @Binding var tab: RootView.Tab
    @Binding var journalMode: JournalView.Mode
    @Binding var listenPath: NavigationPath
    @Binding var journalPath: NavigationPath
    @Binding var guidePath: NavigationPath
    @Binding var circlesPath: NavigationPath
    @Binding var showingDeveloper: Bool
    @State private var showingGlance = false

    func body(content: Content) -> some View {
        content
        .fullScreenCover(isPresented: $showingGlance) { GlancePreview() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, UserDefaults.standard.bool(forKey: "autoLensBackInBackground") { connection.injectMockInput(.back) }
        }
        .task {
            let defaults = UserDefaults.standard
            let stopAfter = defaults.double(forKey: "autoRunStopAfter")
            if stopAfter > 0 {
                Task {
                    run.source = .phone
                    run.fakeStack = FakeRunBirds.stack
                    await run.start()
                    try? await Task.sleep(for: .seconds(stopAfter))
                    await run.stop()
                }
            }
            if defaults.bool(forKey: "seedJournal") { DebugSeeds.seedJournal(context: context, frames: frameStore) }
            if defaults.bool(forKey: "seedReferenceBirds") { DebugSeeds.seedReferenceBirds(context: context) }
            if defaults.bool(forKey: "seedGallery") { DebugSeeds.seedGallery(context: context, frames: frameStore) }
            if defaults.bool(forKey: "seedBoard") { DebugSeeds.seedBoard(context: context) }
            if let place = defaults.string(forKey: "seedNewestAt").flatMap(DebugPlace.init(rawValue:)) { DebugSeeds.seedNewest(at: place, context: context) }
            let large = defaults.integer(forKey: "seedLarge")
            if large > 0 { DebugSeeds.seedLarge(context: context, count: large) }
            for index in 0..<defaults.integer(forKey: "seedUnnamed") {
                _ = try? run.sightings.recorder.recordCapture(photo: DebugSeeds.frameJPEG(), takenAt: Date.now.addingTimeInterval(-86_400 * Double(index + 1)), location: DebugPlace.griffith.coordinate, source: .phone)
            }
            if let seen = defaults.string(forKey: "seedSeen") {
                // Written by the recorder alone, as a naming on an earlier day left them: no run, no reveal.
                let fieldGuide = library.fieldGuideBirds
                let names = NameableBirds.loadOrFieldGuideOnly(fieldGuide: fieldGuide)
                let recorder = run.sightings.recorder
                for (index, bird) in seen.split(separator: ",").compactMap({ names.bird(scientificName: String($0)) }).enumerated() {
                    if let capture = try? recorder.recordCapture(photo: DebugSeeds.frameJPEG(), takenAt: Date.now.addingTimeInterval(-3_600 * Double(index + 1)), location: DebugPlace.griffith.coordinate, source: .phone) {
                        _ = try? recorder.name(capture, as: bird)
                    }
                }
            }
            if defaults.bool(forKey: "speedTour") {
                let tour = SpeedTour(
                    context: context, run: run, library: library, circles: circles,
                    tab: $tab, journalMode: $journalMode, journalPath: $journalPath, guidePath: $guidePath, circlesPath: $circlesPath
                )
                Task { await tour.walk() }
                return
            }
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
                if let seen = defaults.string(forKey: "autoIdleSeen") {
                    let fieldGuide = library.fieldGuideBirds
                    let names = NameableBirds.loadOrFieldGuideOnly(fieldGuide: fieldGuide)
                    let place = defaults.string(forKey: "autoLocation").flatMap(DebugPlace.init(rawValue:))?.coordinate
                    for bird in seen.split(separator: ",").compactMap({ names.bird(scientificName: String($0)) }) {
                        guard let unnamed = try? run.sightings.capture(photo: DebugSeeds.frameJPEG(), takenAt: .now, location: place, source: .phone, onThisRun: false) else { continue }
                        run.name(unnamed, as: bird)
                        run.finishCeremony()
                        run.dismissReveal()
                    }
                }
            case "idle-capture", "idle-name-bird":
                tab = .listen
                if screen == "idle-name-bird" { defaults.set(true, forKey: "autoNameBird") }
                run.isCapturing = true
            case "listening", "review", "capture", "name-bird":
                tab = .listen
                run.source = .phone
                run.fakeStack = FakeRunBirds.stack
                await run.start()
                if defaults.double(forKey: "fakeRunReorderEvery") > 0 {
                    FakeRunBirds.keepReordering(run, every: defaults.double(forKey: "fakeRunReorderEvery"))
                }
                if let name = defaults.string(forKey: "autoRowAdd"), let bird = run.candidates.first(where: { $0.species.commonName == name }) {
                    // `-autoRowAddAfter <seconds>`: late enough for a screenshot to catch its acknowledgment.
                    try? await Task.sleep(for: .seconds(defaults.double(forKey: "autoRowAddAfter")))
                    await run.addFromRow(bird, isDescribed: true)
                    run.finishCeremony()
                    run.dismissReveal()
                }
                for _ in 0..<defaults.integer(forKey: "autoUnnamed") {
                    run.capture(CapturedPhoto(data: DebugSeeds.frameJPEG(), takenAt: .now))
                }
                if defaults.bool(forKey: "autoRunStops") {
                    await run.stop()
                }
                if let seen = defaults.string(forKey: "autoSeen") {
                    let fieldGuide = library.fieldGuideBirds
                    let names = NameableBirds.loadOrFieldGuideOnly(fieldGuide: fieldGuide)
                    for bird in seen.split(separator: ",").compactMap({ names.bird(scientificName: String($0)) }) {
                        run.addSeen(bird, photo: CapturedPhoto(data: DebugSeeds.frameJPEG(), takenAt: .now))
                        run.finishCeremony()
                        run.dismissReveal()
                    }
                }
                if screen == "capture" || screen == "name-bird" {
                    if screen == "name-bird" { defaults.set(true, forKey: "autoNameBird") }
                    run.isCapturing = true
                }
                if screen == "review" {
                    // The WAV's first admissions take a few windows; wait for a bird the packs describe, so the
                    // review shows a photo, else take the first.
                    for _ in 0..<120 where !run.candidates.contains(where: { library.species(scientificName: $0.species.scientificName) != nil }) {
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                    run.reviewing = run.candidates.first { library.species(scientificName: $0.species.scientificName) != nil } ?? run.candidates.first
                }
            case "recap":
                // A phone run that ends on its recap (issue #150): the first bird the packs describe added, then Stop.
                tab = .listen
                run.source = .phone
                await run.start()
                for _ in 0..<240 where !run.candidates.contains(where: { library.species(scientificName: $0.species.scientificName) != nil }) {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                if defaults.bool(forKey: "autoRecapAdd"), let candidate = run.candidates.first(where: { library.species(scientificName: $0.species.scientificName) != nil }) {
                    await run.add(candidate)
                    run.dismissReveal()
                }
                await run.stop()
            case "glance":
                showingGlance = true
            case "glasses-run":
                tab = .listen
                connection.pairMockGlasses()
                for _ in 0..<100 where connection.connectedDevice == nil {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                run.source = .glasses
                await run.start()
                // This launch's choice, not one for the simulator's next UI test to find remembered.
                defaults.removeObject(forKey: ListeningCoordinator.sourceKey)
                let lens = MockLensAdds(lens: run.glasses.lens, connection: connection, sightings: run.sightings)
                if defaults.string(forKey: "autoGlassesMicrophone") == "denied" { connection.denyMockMicrophone() }
                for _ in 0..<defaults.integer(forKey: "autoLensCapture") {
                    await lens.capture(saying: defaults.string(forKey: "autoLensSay"))
                }
                for name in (defaults.string(forKey: "autoLensAdd") ?? "").split(separator: ",") {
                    await lens.add(String(name))
                }
            case "journal", "cards":
                tab = .journal
                journalMode = .cards
                // `-autoLiftAfter <s>` opens the `-autoCardSpecies` patch from its tile that long after launch, and `-autoLiftBackAfter
                // <s>` goes back that long after, with no tap a UI test would wait out (issue #150).
                let liftAfter = defaults.double(forKey: "autoLiftAfter")
                if liftAfter > 0, let species = defaults.string(forKey: "autoCardSpecies") {
                    try? await Task.sleep(for: .seconds(liftAfter))
                    let all = (try? context.fetch(Sighting.newestFirst())) ?? []
                    if let sighting = all.first(where: { $0.scientificName == species }) {
                        let placement = CardCollection(sightings: all, sets: library.cardSets).placement(of: sighting.identifier)
                        journalPath.append(Route.patch(CardCollection.Patch.Key(speciesID: sighting.speciesID, setID: placement?.setID), from: .board))
                        let backAfter = defaults.double(forKey: "autoLiftBackAfter")
                        if backAfter > 0 {
                            try? await Task.sleep(for: .seconds(backAfter))
                            journalPath.removeLast()
                        }
                    }
                }
            case "sightings":
                tab = .journal
                journalMode = .sightings
            case "reveal":
                tab = .listen
                let revealDelay = defaults.double(forKey: "autoRevealDelay")
                if revealDelay > 0 {
                    tab = .journal
                    try? await Task.sleep(for: .seconds(revealDelay))
                }
                // With `-autoPhoneListening`, over a run, as after a real add (issue #117's screenshots).
                if defaults.string(forKey: "autoPhoneListening") != nil {
                    run.source = .phone
                    await run.start()
                }
                let species = defaults.string(forKey: "autoCardSpecies")
                let all = (try? context.fetch(Sighting.newestFirst())) ?? []
                if let newest = all.first(where: { species == nil || $0.scientificName == species }) {
                    // As an add would have, with the fake signed in and sharing. Never a real account's real find.
                    if defaults.string(forKey: "fakeAccount") != nil { findOutbox.added(newest.identifier, isNewPatch: true) }
                    run.showRevealForScreenshot(of: newest, placement: CardCollection(sightings: all, sets: library.cardSets).placement(of: newest.identifier) ?? .uncharted)
                }
            case "card", "card-back":
                tab = .journal
                journalMode = .cards
                let species = defaults.string(forKey: "autoCardSpecies")
                let all = (try? context.fetch(Sighting.newestFirst())) ?? []
                if let newest = all.first(where: { species == nil || $0.scientificName == species }) {
                    let placement = CardCollection(sightings: all, sets: library.cardSets).placement(of: newest.identifier)
                    journalPath.append(Route.patch(CardCollection.Patch.Key(speciesID: newest.speciesID, setID: placement?.setID)))
                }
                if screen == "card-back" { defaults.set(true, forKey: "autoCardBack") }
            case "species", "gallery":
                tab = .journal
                journalMode = .species
                // `-autoCardSpecies` opens that bird's page, found or not (issue #138's not-yet-found state).
                if let species = defaults.string(forKey: "autoCardSpecies") {
                    journalPath.append(Route.speciesPatches(scientificName: species, commonName: library.species(scientificName: species)?.species.commonName ?? species))
                } else if let newest = try? context.fetch(Sighting.newestFirst()).first {
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
                let scientificName = defaults.string(forKey: "autoCardSpecies") ?? "Sayornis nigricans"
                guidePath.append(Route.species(scientificName: scientificName, commonName: library.species(scientificName: scientificName)?.species.commonName ?? scientificName))
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
            case "app-icon":
                tab = .listen
                listenPath.append(Route.settings)
                listenPath.append(Route.appIcon)
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
            case "find":
                // A find's page (issue #150): `-autoFind <owner>/<sighting>`, on the first Guild, by default Maya's Black Phoebe.
                tab = .circles
                await circles.refresh()
                await circles.loadMergedFeed()
                let find = defaults.string(forKey: "autoFind") ?? "maya/00000000-0000-4000-8000-000000000000"
                circlesPath.append(Route.find(FindRoute(itemID: find)))
            case "circle", "circle-invite", "circle-goal", "circle-report", "circle-info":
                tab = .circles
                await circles.refresh()
                if let first = circles.circles.first {
                    if screen == "circle-invite" { defaults.set(true, forKey: "autoCircleInvite") }
                    if screen == "circle-info" { defaults.set(true, forKey: "autoCircleInfo") }
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
            case "goal-patches":
                // The first circle's page, then every patch of its month (issue #150).
                tab = .circles
                await circles.refresh()
                if let first = circles.circles.first {
                    circlesPath.append(Route.circle(id: first.id))
                    await circles.loadGoals(circleID: first.id)
                    if let monthly = circles.goals[first.id]?.first(where: { $0.kind == .monthly }) {
                        circlesPath.append(Route.goalPatches(circleID: first.id, goalID: monthly.id))
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

/// The places `-autoLocation` names: one in each set, and one outside them all.
enum DebugPlace: String {
    case griffith, sanDiego = "san-diego", oakland, joshuaTree = "joshua-tree", orlando, kansas

    var coordinate: Coordinate {
        switch self {
        case .griffith: Coordinate(latitude: 34.1365, longitude: -118.2942, accuracy: 10)
        case .sanDiego: Coordinate(latitude: 32.7157, longitude: -117.1611, accuracy: 10)
        case .oakland: Coordinate(latitude: 37.8044, longitude: -122.2712, accuracy: 10)
        case .joshuaTree: Coordinate(latitude: 33.8734, longitude: -115.9010, accuracy: 10)
        case .orlando: Coordinate(latitude: 28.5384, longitude: -81.3789, accuracy: 10)
        case .kansas: Coordinate(latitude: 38.5, longitude: -98.5, accuracy: 10)
        }
    }
}

/// Stands in for Core Location with a fix in one place (`-autoLocation griffith`, issue #135: a run in the Los Angeles set, so
/// an add there sews a patch with a painting), with no permission prompt for a UI test to answer.
struct FixedLocationProvider: LocationProvider {
    let place: DebugPlace

    func fixes() -> AsyncStream<LocationFix> {
        AsyncStream { continuation in
            continuation.yield(.fix(latitude: place.coordinate.latitude, longitude: place.coordinate.longitude, accuracy: place.coordinate.accuracy, at: .now))
            continuation.finish()
        }
    }

    func lastKnownCoordinate() -> Coordinate? { place.coordinate }
}

/// Hands a file's chunks out at the pace they were recorded, so a WAV drives the Listen tab like a microphone would
/// instead of ending in a second.
final class PacedAudioSource: AudioSource {
    private let base: any AudioSource
    private let endPacing = Mutex<(@Sendable () -> Void)?>(nil)

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
        endPacing.withLock {
            $0 = {
                forwarding.cancel()
                continuation.finish()
            }
        }
        return paced
    }

    /// Stops at once, as a microphone does, not after what the file has already handed over has played out.
    func stop() async {
        await base.stop()
        endPacing.withLock { $0 }?()
    }
}

/// A glasses run's stream for the simulator, where the mock injects no audio: a file at a microphone's pace, and no camera,
/// or with `hasCamera` (`-autoGlassesCamera YES`, issue #193) a drawn frame standing in for the stream's, so the lens's
/// viewfinders show a picture and a photo taken there is that frame.
final class PacedGlassesAudioSource: FrameKeepingAudioSource {
    private let base: PacedAudioSource
    private let frame: CameraFrame?

    init(url: URL, hasCamera: Bool = false) {
        base = PacedAudioSource(WAVFileAudioSource(url: url))
        let jpeg = hasCamera ? DebugSeeds.frameJPEG() : nil
        frame = jpeg.map { jpeg in CameraFrame(jpegData: { jpeg }) }
    }

    var latestFrame: CameraFrame? { frame }
    func start() async throws -> AsyncStream<AudioChunk> { try await base.start() }
    func stop() async { await base.stop() }
    func capturePhoto() async -> Data? { nil }
    func ensureStreaming(_ reason: String) async {}
    func suspend() async {}
    func resume(on session: DeviceSession) async throws {}
}

/// Adds birds on the lens through Mock Device Kit's inputs, as a wearer would: down the list to the bird, onto its page, down
/// to its details, Add to my list, and a swipe off the viewfinder, which adds it without a photo; then back to the list.
struct MockLensAdds {
    let lens: GlassesLensSession
    let connection: GlassesConnection
    let sightings: RunSightings

    func add(_ name: String) async {
        func candidateIndex() -> Int? { lens.stack.candidates.firstIndex { $0.species.commonName == name } }
        guard await wait(seconds: 120, until: { lens.inputsState == .active && candidateIndex() != nil }) else { return }
        // A new bird or a call can move the list between inputs: if the wrong bird opens, back and again.
        for _ in 0..<5 {
            guard let index = candidateIndex() else { return }
            for _ in 0..<lens.stack.count where lens.machine.selection != index {
                let (position, target) = (lens.machine.order.position(of: lens.machine.selection) ?? 0, lens.machine.order.position(of: index) ?? 0)
                let before = lens.inputRecords.count
                connection.injectMockInput(target > position ? .navDown : .navUp)
                _ = await wait(seconds: 1) { lens.inputRecords.count > before }
            }
            connection.injectMockInput(.navLeft)
            _ = await wait(seconds: 2) { lens.page != .list }
            if lens.page == .species(index: index) { break }
            connection.injectMockInput(.back)
            _ = await wait(seconds: 2) { lens.page == .list }
        }
        guard let index = candidateIndex(), lens.page == .species(index: index) else { return }
        let saved = sightings.entries.count
        connection.injectMockInput(.navDown)
        _ = await wait(seconds: 2) { lens.page == .details(index: index) }
        connection.injectMockInput(.select)
        _ = await wait(seconds: 2) { lens.page == .viewfinder(index: index) }
        connection.injectMockInput(.navRight)
        _ = await wait(seconds: 5) { sightings.entries.count > saved }
        _ = await wait(seconds: 2) { lens.page == .details(index: index) }
        connection.injectMockInput(.back)
        _ = await wait(seconds: 2) { lens.page == .list }
    }

    /// Takes a photo from the lens as a wearer would (issue #193): up to "Capture a sighting", a tap, a moment for the
    /// viewfinder's echo window, and a tap on the viewfinder; then back to the list, with the highlight on the first bird again.
    /// Where the lens asks for the bird's name (issue #194), the mock's glasses hear `words` and the first bird offered is
    /// chosen; with no words, or no bird for them, the photo is left to be named later.
    func capture(saying words: String? = nil) async {
        guard await wait(seconds: 120, until: { lens.inputsState == .active }) else { return }
        for _ in 0...lens.stack.count where !lens.machine.isCaptureRowHighlighted {
            let before = lens.inputRecords.count
            connection.injectMockInput(.navUp)
            _ = await wait(seconds: 1) { lens.inputRecords.count > before }
        }
        let taken = sightings.unnamed.count + sightings.seen.count
        connection.injectMockInput(.select)
        guard await wait(seconds: 2, until: { lens.page == .captureViewfinder }) else { return }
        try? await Task.sleep(for: .milliseconds(1200))
        connection.injectMockInput(.select)
        _ = await wait(seconds: 10) { sightings.unnamed.count + sightings.seen.count > taken }
        _ = await wait(seconds: 5) { lens.page == .captureSaved || lens.page == .captureNaming }
        if lens.page == .captureNaming {
            if let words, await wait(seconds: 5, until: { connection.mockSpeechIsListening }) {
                connection.simulateMockSpeech(words, isFinal: true)
                if await wait(seconds: 10, until: { lens.page == .captureMatches }), lens.machine.naming?.matches.isEmpty == false {
                    connection.injectMockInput(.select)
                    _ = await wait(seconds: 5) { lens.page == .captureAdded }
                }
            } else {
                // A tap while the glasses listen: name it later.
                connection.injectMockInput(.select)
                _ = await wait(seconds: 2) { lens.page == .captureSaved }
            }
        }
        // Swipe right leaves the saved page, the birds' page and "Added" alike.
        connection.injectMockInput(.navRight)
        _ = await wait(seconds: 2) { lens.page == .list }
        connection.injectMockInput(.navDown)
        _ = await wait(seconds: 1) { !lens.machine.isCaptureRowHighlighted }
    }

    private func wait(seconds: Double, until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }
}

/// The Developer lens's stand-in for a run when a bird's name is said (issue #194): that lens has no run behind it, so
/// this knows the photos it took, matches what the mock's glasses heard against the names (the birds of the fake stack as
/// heard this run, no place), and names a photo through the coordinator, as the phone would.
final class MockLensNaming {
    private let run: ListeningCoordinator
    private let fieldGuide: [NameableBirds.FieldGuideBird]
    private var names: NameableBirds?
    /// The photos taken from the lens, by the lens's number for each.
    var captured: [Int: UnnamedSighting] = [:]
    private var offered: [String: NameableBird] = [:]

    init(run: ListeningCoordinator, fieldGuide: [NameableBirds.FieldGuideBird]) {
        self.run = run
        self.fieldGuide = fieldGuide
    }

    func source(heard: @escaping () -> [String]) -> LensNameSource {
        LensNameSource(
            matches: { [self] words, capture in
                if names == nil {
                    let fieldGuide = fieldGuide
                    names = await Task.detached { NameableBirds.loadOrFieldGuideOnly(fieldGuide: fieldGuide) }.value
                }
                guard let names, let unnamed = captured[capture] else { return [] }
                let birds = names.spoken(words, in: NameableBirds.Context(heard: heard()))
                offered = Dictionary(birds.map { ($0.scientificName, $0) }, uniquingKeysWith: { first, _ in first })
                return birds.map { bird in
                    LensNameMatch(id: bird.scientificName, commonName: bird.commonName, isNewPatch: run.sightings.recorder.patchCount(ofSpeciesID: bird.speciesID, at: unnamed.location) == 0)
                }
            },
            name: { [self] capture, match in
                guard let unnamed = captured[capture], let bird = offered[match.id] else { return .notWritten }
                guard let addition = run.name(unnamed, as: bird) else {
                    // Named or deleted on the phone meanwhile, or the save failed and the photo still waits.
                    return run.sightings.recorder.capture(unnamed.id) == nil ? .gone : .notWritten
                }
                captured[capture] = nil
                return .named(LensNamedCapture(addition, commonName: bird.commonName))
            }
        )
    }
}

// A photo taken and named in one step, for the launch flags and the tests: the app itself always writes the photo at the
// shutter (`capture`) and names it afterwards (`name`). If the naming fails the photo is kept, unnamed.
extension RunSightings {
    /// - Parameter source: the device that took the photo.
    @discardableResult
    func addSeen(_ bird: NameableBird, photo: Data, takenAt: Date, location: Coordinate?, source: SightingSource) throws -> Addition {
        try name(capture(photo: photo, takenAt: takenAt, location: location, source: source), as: bird)
    }
}

extension ListeningCoordinator {
    @discardableResult
    func addSeen(_ bird: NameableBird, photo: CapturedPhoto) -> RunSightings.Addition? {
        guard let unnamed = capture(photo) else { return nil }
        return name(unnamed, as: bird)
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

    /// The birds `5-compare.png` says are yours (issue #150), for its side-by-side: two you share with Maya, and three only you have.
    static func seedReferenceBirds(context: ModelContext) {
        let griffithPark = Coordinate(latitude: 34.1365, longitude: -118.2942, accuracy: 15)
        let birds = ["Sayornis nigricans_Black Phoebe", "Haemorhous mexicanus_House Finch", "Calypte anna_Anna's Hummingbird", "Zenaida macroura_Mourning Dove", "Branta canadensis_Canada Goose"]
        for (index, label) in birds.enumerated() {
            context.insert(Sighting(speciesID: label, confirmedAt: Date.now.addingTimeInterval(Double(-index - 1) * 3600), location: griffithPark, soundConfidence: 0.8, frameImagePath: nil, source: .phone, note: nil))
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

    /// A House Finch just now at `place`, on top of any other seed: the newest sighting's set, for the painting's fallback (issue #150).
    static func seedNewest(at place: DebugPlace, context: ModelContext) {
        context.insert(Sighting(speciesID: "Haemorhous mexicanus_House Finch", confirmedAt: .now, location: place.coordinate, soundConfidence: 0.7, frameImagePath: nil, source: .phone, method: .heard))
        try? context.save()
    }

    /// The label an add writes for this bird, the identification model's: a pack's own `birdnetLabel` is only its scientific name,
    /// so a run's rows and the sightings it adds would be different birds.
    static func sightingLabel(_ species: PackSpecies) -> String {
        "\(species.scientificName)_\(species.commonName)"
    }

    /// One sighting of each of the bundled pack's first 30 birds, a minute apart.
    static func seedBoard(context: ModelContext) {
        let griffithPark = Coordinate(latitude: 34.1365, longitude: -118.2942, accuracy: 15)
        for (index, species) in ((try? SpeciesPack.bundled().species) ?? []).prefix(30).enumerated() {
            context.insert(Sighting(speciesID: sightingLabel(species), confirmedAt: Date.now.addingTimeInterval(-Double(index) * 60), location: griffithPark, soundConfidence: 0.7, source: .phone))
        }
        try? context.save()
    }

    /// A big album for profiling (issue #150): `count` sightings of the bundled pack's birds over three years, most of them in
    /// Los Angeles, some in San Diego and some far from every set, in a repeatable order. Does nothing to an album that's
    /// already that big.
    static func seedLarge(context: ModelContext, count: Int) {
        let existing = (try? context.fetchCount(FetchDescriptor<Sighting>())) ?? 0
        guard existing < count else { return }
        let labels = ((try? SpeciesPack.bundled().species) ?? []).map(sightingLabel)
        guard !labels.isEmpty else { return }
        var random = SplitMix(state: 150)
        for index in existing..<count {
            let label = labels[Int(random.next() % UInt64(labels.count))]
            let jitter = { (random: inout SplitMix) in Double(random.next() % 1000) / 1000 * 0.1 - 0.05 }
            let location: Coordinate? = switch index % 10 {
            case 0...6: Coordinate(latitude: 34.1365 + jitter(&random), longitude: -118.2942 + jitter(&random), accuracy: 15)
            case 7, 8: Coordinate(latitude: 32.7341 + jitter(&random), longitude: -117.1446 + jitter(&random), accuracy: 15)
            default: index % 20 == 9 ? nil : Coordinate(latitude: 39.5 + jitter(&random), longitude: -116.9 + jitter(&random), accuracy: 15)
            }
            let hoursAgo = Double(random.next() % (3 * 365 * 24))
            context.insert(Sighting(speciesID: label, confirmedAt: Date.now.addingTimeInterval(-hoursAgo * 3600), location: location, soundConfidence: 0.7, source: .phone))
        }
        try? context.save()
    }

    private struct SplitMix {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
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
/// `-fakeRunBirds`: a run's list from the launch arguments.
enum FakeRunBirds {
    /// The birds after the first, always calling, pass their last-heard times along, so each in turn comes up first among them.
    static func keepReordering(_ run: ListeningCoordinator, every seconds: Double) {
        Task { @MainActor in
            while let stack = run.fakeStack {
                try? await Task.sleep(for: .seconds(seconds))
                let birds = stack.candidates
                guard birds.count > 2 else { return }
                let earlier = birds.dropFirst().map(\.lastHeardAt)
                let passed = Array(earlier.dropFirst()) + [earlier[0]]
                run.fakeStack = CandidateStack(candidates: [birds[0]] + zip(birds.dropFirst(), passed).map { bird, heard in
                    Candidate(species: bird.species, score: bird.score, windowsAboveThreshold: bird.windowsAboveThreshold, firstHeardAt: bird.firstHeardAt, lastHeardAt: heard, admittedAt: bird.admittedAt)
                })
            }
        }
    }

    static var stack: CandidateStack? {
        guard let labels = UserDefaults.standard.string(forKey: "fakeRunBirds") else { return nil }
        return CandidateStack(candidates: labels.split(separator: ",").enumerated().map { position, label in
            let parts = label.split(separator: "_", maxSplits: 1).map(String.init)
            let species = Species(index: position, scientificName: parts[0], commonName: parts.last ?? parts[0], taxonomicClass: "Aves")
            // A clock far ahead keeps the first calling for good; the others fell quiet before the run began.
            let heard = position == 0 ? 1_000_000 : Double(-60 * (2 * position + 1))
            return Candidate(species: species, score: 0.8, windowsAboveThreshold: 2, firstHeardAt: 0, lastHeardAt: heard, admittedAt: Double(position))
        })
    }
}
#endif
