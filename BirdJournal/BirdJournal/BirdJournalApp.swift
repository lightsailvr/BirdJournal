import Album
import Identification
import MWDATCamera
import MWDATCore
import OSLog
import Pack
import SwiftData
import SwiftUI

@main
struct BirdJournalApp: App {
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var appDelegate
    @State private var connection: GlassesConnection
    @State private var spike: SpikeRecorder
    @State private var lens: GlassesLensSession
    @State private var phoneListening: ListeningSession
    @State private var glassesListening: GlassesListeningSession
    @State private var listening: ListeningCoordinator
    @State private var sounds: ReferenceSounds
    @State private var places: PlaceNames
    @State private var packs: PackLibrary
    @State private var collectionStore: CollectionStore
    @State private var place: CurrentPlace
    @State private var journalEdits: JournalEdits
    @State private var account: AccountSession
    @State private var circles: CircleStore
    @State private var findOutbox: FindOutbox
    @State private var pushes: PushCenter
    /// A patch the widget opened, until the root has shown it.
    @State private var pendingPatch: CardCollection.Patch.Key?
    private let album: ModelContainer
    private let frames: FrameStore
    private let runActivity: RunActivityController
    private let latestPatch: LatestPatchPublisher?
    private let recorder: SightingRecorder

    init() {
        let launchSignposter = OSSignposter(subsystem: "com.matthewcelia.mybirdjournal", category: "launch")
        let initialization = launchSignposter.beginInterval("App init")
        defer { launchSignposter.endInterval("App init", initialization) }
        let configure = launchSignposter.beginInterval("Configure wearables")
        do {
            try Wearables.configure()
        } catch {
            Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "glasses")
                .error("Wearables.configure failed: \(error.localizedDescription)")
        }
        launchSignposter.endInterval("Configure wearables", configure)
        JournalFont.applyNavigationBarAppearance()
        let connection = GlassesConnection()
        let openAlbum = launchSignposter.beginInterval("Open album store")
        let album = Self.makeAlbum()
        launchSignposter.endInterval("Open album store", openAlbum)
        let frames = Self.makeFrameStore()
        let packs = PackLibrary.forApp(deferred: true)
        let levels = LevelSink()
        // The reference clips the profile plays (issue #41) are silenced in whichever run is listening.
        let suppression = AudioSuppression()
        let recorder = SightingRecorder(container: album, frames: frames, rarity: BundledIdentification.rarityReader())
        recorder.sets = { packs.cardSets }
        self.recorder = recorder
        let sightings = RunSightings(recorder: recorder)
        let places = PlaceNames()
        sightings.captioner = Self.makeCaptioner(packs: packs, places: places)
        _places = State(initialValue: places)
        let phone = Self.makePhoneListeningSession(levels: levels, suppression: suppression)
        let glasses = Self.makeGlassesListeningSession(connection: connection, recorder: recorder, sightings: sightings, packs: packs, levels: levels, suppression: suppression)
        let listening = ListeningCoordinator(
            phone: phone, glasses: glasses, sightings: sightings, levels: levels,
            defaultSource: connection.devices.isEmpty ? .phone : .glasses,
            archive: Self.endedRunArchive()
        )
        self.album = album
        self.frames = frames
        let account = AccountSession.forApp()
        _account = State(initialValue: account)
        let loadCircles = launchSignposter.beginInterval("Read Guild cache")
        let circles = CircleStore.forApp(account: account)
        launchSignposter.endInterval("Read Guild cache", loadCircles)
        _circles = State(initialValue: circles)
        // Finds (issue #62): adds made while signed in and sharing reach the birder's circles.
        let loadOutbox = launchSignposter.beginInterval("Read find outbox")
        let findOutbox = FindOutbox.forApp(account: account, client: circles.client, album: album, packs: packs, places: places)
        launchSignposter.endInterval("Read find outbox", loadOutbox)
        sightings.findOutbox = findOutbox
        _findOutbox = State(initialValue: findOutbox)
        // Pushes (issue #63): permission at the first circle, the token to the account, and a refresh on every push.
        let pushes = PushCenter.forApp(account: account, client: circles.client) { UIApplication.shared.registerForRemoteNotifications() }
        pushes.refresh = { [weak circles] circleIDs in await circles?.refreshAfterPush(circleIDs: circleIDs) }
        circles.joinedCircle = { [weak pushes] in await pushes?.joinedCircle() }
        PushAppDelegate.pushes = pushes
        _pushes = State(initialValue: pushes)
        _connection = State(initialValue: connection)
        _spike = State(initialValue: SpikeRecorder(connection: connection))
        _packs = State(initialValue: packs)
        let collectionStore = CollectionStore(container: album, deferred: true, sets: { packs.cardSets })
        _collectionStore = State(initialValue: collectionStore)
        _place = State(initialValue: CurrentPlace(library: packs, collection: { collectionStore.collection }, location: Self.makePlaceLocation()))
        // The run on the Lock Screen, and the patch on the Home Screen (issue #150). Neither waits for a view: a run goes on
        // behind a locked phone.
        runActivity = RunActivityController(host: ActivityKitRunHost())
        runActivity.follow { [weak listening, collectionStore] in listening?.snapshot(in: collectionStore.collection) ?? .idle }
        RunStopper.stop = { [weak listening] in await listening?.stop() }
        latestPatch = WidgetStore.shared.map { LatestPatchPublisher(store: $0, collection: collectionStore, packs: packs) }

        let lens = Self.makeLensSession(connection: connection, packs: packs)
        _lens = State(initialValue: lens)
        _phoneListening = State(initialValue: phone)
        _glassesListening = State(initialValue: glasses)
        _listening = State(initialValue: listening)
        let sounds = ReferenceSounds(
            player: AVSoundPlayer(), session: SystemPlaybackAudioSession(), suppression: suppression,
            phoneRunHoldsSession: { [weak listening] in listening?.phoneRunHoldsSession ?? false },
            glassesStream: { [weak glasses] in glasses?.playbackStreamHold },
            lookup: { packs.soundAndFile(id: $0) }
        )
        // The lens's sounds pages play through the same player as the profile (issue #41, phase 4).
        glasses.lens.sounds = sounds
        lens.sounds = sounds
        // A friend's notable find, foreground or background, becomes a banner on the lens of a run (issue #67).
        _ = FriendBanners.forward(pushes.friendFinds()) { [glasses, lens] in [glasses.lens, lens] }
        _sounds = State(initialValue: sounds)
        let journalEdits = JournalEdits(container: album, frames: frames)
        journalEdits.findOutbox = findOutbox
        _journalEdits = State(initialValue: journalEdits)
    }

    /// The album on disk. Failing to open it is a broken install, not a field condition, so it traps like the
    /// `.modelContainer(for:)` modifier it replaces did, rather than silently saving sightings to memory. In debug
    /// builds `-inMemoryAlbum YES` keeps the album in memory, so screenshot runs can seed it without leaving a trace, and
    /// `-albumFile <name>` keeps it in a file of its own in tmp, so a UI test can relaunch over the same album.
    private static func makeAlbum() -> ModelContainer {
        var inMemory = false
        #if DEBUG
        inMemory = UserDefaults.standard.bool(forKey: "inMemoryAlbum")
        #endif
        do {
            #if DEBUG
            if let name = UserDefaults.standard.string(forKey: "albumFile") {
                return try AlbumSchema.makeContainer(at: URL.temporaryDirectory.appending(path: "\(name).store"))
            }
            #endif
            return try AlbumSchema.makeContainer(inMemory: inMemory)
        } catch {
            fatalError("album store unavailable: \(error)")
        }
    }

    /// Where a review waiting to be seen outlives the app. In debug builds it goes with the album: nothing for one in memory,
    /// which is gone by the next launch, and a suite of its own for `-albumFile`.
    private static func endedRunArchive() -> UserDefaults? {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "inMemoryAlbum") { return nil }
        if let name = UserDefaults.standard.string(forKey: "albumFile") { return UserDefaults(suiteName: "album-\(name)") }
        #endif
        return .standard
    }

    /// The caption writer every add uses (issue #56): Apple's on-device model over the packs' fact sheets, with the
    /// place named by the phone's reverse geocoding. In debug builds `-captionWriter fixed` writes a fixed line instead,
    /// for simulators without Apple Intelligence, and `-captionWriter none` none.
    private static func makeCaptioner(packs: PackLibrary, places: PlaceNames) -> Captioner? {
        var writer: any CaptionWriter = FoundationModelsCaptionWriter()
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "captionWriter") {
        case "fixed": writer = FixedCaptionWriter()
        case "none": return nil
        default: break
        }
        #endif
        return Captioner(
            writer: writer,
            species: { name in
                packs.species(scientificName: name).map { Captioner.Species(commonName: $0.species.commonName, facts: $0.species.facts.map(\.text), isThreatened: $0.species.isThreatened) }
            },
            placeLabel: { coordinate in
                await places.resolve(coordinate)
                return places.name(for: coordinate)
            }
        )
    }

    /// Sightings saved before rarity existed get theirs once (issue #52), after launch and with the geomodel read off
    /// the main actor. The debug in-memory album is skipped: it would mark the album on disk as done.
    private static func backfillRarity(_ recorder: SightingRecorder) {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "inMemoryAlbum") || UserDefaults.standard.string(forKey: "albumFile") != nil { return }
        #endif
        Task(priority: .utility) {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            await recorder.backfillRarity()
        }
    }

    /// Where sightings' frames go, beside the album; the album screens read them from the same store. With the
    /// debug in-memory album the frames go to a fresh tmp folder, so a screenshot run leaves nothing behind.
    private static func makeFrameStore() -> FrameStore {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "inMemoryAlbum") {
            return FrameStore(directory: URL.temporaryDirectory.appending(path: "Frames-\(UUID().uuidString)", directoryHint: .isDirectory))
        }
        #endif
        do {
            return try FrameStore.applicationSupport()
        } catch {
            // iOS purges tmp, so frames saved there can vanish; the sighting keeps the path and the album shows no image.
            Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "album")
                .error("Application Support unavailable, frames go to tmp: \(error.localizedDescription)")
            return FrameStore(directory: URL.temporaryDirectory.appending(path: "Frames", directoryHint: .isDirectory))
        }
    }

    /// The lens session over the species packs: the species cards' photos and text come from the first pack that has
    /// the species (bundled first, then downloads, read live so a pack downloaded mid-run counts), and a species no
    /// pack has shows by name alone.
    private static func makeLensSession(connection: GlassesConnection, packs: PackLibrary) -> GlassesLensSession {
        GlassesLensSession(connection: connection, profile: { packs.profile(for: $0) }, image: { packs.image(for: $0) })
    }

    /// The whole loop on the glasses (issue #9), writing sightings to the album through the run ledger the phone's
    /// adds share (issue #28), and reporting the audio level for the waveform.
    private static func makeGlassesListeningSession(connection: GlassesConnection, recorder: SightingRecorder, sightings: RunSightings, packs: PackLibrary, levels: LevelSink, suppression: AudioSuppression) -> GlassesListeningSession {
        var makeSource: (DeviceSession) -> any FrameKeepingAudioSource = { session in
            GlassesAudioSource(lease: .shared(session), sampleRate: .rate44100, onLevel: { levels.level = $0 })
        }
        var location: any LocationProvider = CoreLocationProvider()
        #if DEBUG
        // `-autoGlassesListening <wav>` with `-autoScreen glasses-run`: the mock injects no audio, so the file stands in for
        // the stream. Everything else is the real run on Mock Device Kit.
        if let path = UserDefaults.standard.string(forKey: "autoGlassesListening"), path.hasSuffix(".wav") {
            let hasCamera = UserDefaults.standard.bool(forKey: "autoGlassesCamera")
            makeSource = { _ in PacedGlassesAudioSource(url: URL(fileURLWithPath: path), hasCamera: hasCamera) }
            location = debugLocationProvider()
        }
        #endif
        return GlassesListeningSession(
            connection: connection,
            recorder: recorder,
            sightings: sightings,
            makeSource: makeSource,
            location: location,
            profile: { packs.profile(for: $0) },
            image: { packs.image(for: $0) },
            suppression: suppression
        )
    }

    /// The phone listening session over the real microphone, metered for the waveform. In debug builds,
    /// `-autoPhoneListening <path.wav>` feeds that file instead, so the screen can be checked on the simulator, whose
    /// audio input is not available, and `-autoLocation denied` skips the location request (a UI test cannot answer
    /// the permission prompt).
    private static func makePhoneListeningSession(levels: LevelSink, suppression: AudioSuppression) -> ListeningSession {
        let meter: @Sendable (AudioLevel) -> Void = { levels.level = $0 }
        #if DEBUG
        if let path = UserDefaults.standard.string(forKey: "autoPhoneListening"), path.hasSuffix(".wav") {
            // Paced like a microphone, so the Listen tab's live state can be seen and screenshotted on the simulator.
            return ListeningSession(makeSource: { MeteredAudioSource(PacedAudioSource(WAVFileAudioSource(url: URL(fileURLWithPath: path))), onLevel: meter) }, location: debugLocationProvider(), suppression: suppression)
        }
        #endif
        return ListeningSession(makeSource: { MeteredAudioSource(PhoneMicAudioSource(), onLevel: meter) }, suppression: suppression)
    }

    /// What picks the Listen painting's set (issue #150): the phone's last known position, which never prompts. `-autoLocation`
    /// stands in for it in debug builds.
    private static func makePlaceLocation() -> any LocationProvider {
        #if DEBUG
        return debugLocationProvider()
        #else
        return CoreLocationProvider()
        #endif
    }

    #if DEBUG
    /// `-autoLocation denied|griffith|…` answers without a permission prompt a UI test couldn't answer.
    private static func debugLocationProvider() -> any LocationProvider {
        switch UserDefaults.standard.string(forKey: "autoLocation") {
        case "denied": DeniedLocationProvider()
        case let name?: DebugPlace(rawValue: name).map(FixedLocationProvider.init) ?? CoreLocationProvider()
        case nil: CoreLocationProvider()
        }
    }
    #endif

    var body: some Scene {
        // Nothing this closure reads may change after launch: SwiftUI can call it from the thread that draws animation frames, and
        // Swift 6 traps it there, since it belongs to the main actor (issue #150). So what changes lives in `AppSurface`, a view,
        // whose body SwiftUI keeps on the main thread. `LaunchUITests` holds it.
        WindowGroup {
            AppSurface(prepare: prepareForLaunch, openURL: handleURL) { isUnderSplash in root(isUnderSplash: isUnderSplash) }
        }
        .modelContainer(album)
    }

    private func prepareForLaunch() async throws {
        #if DEBUG
        // Exercises the real launch gate on a repeat launch without slowing production or touching the album.
        let delay = UserDefaults.standard.double(forKey: "launchLoadDelay")
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        #endif
        async let shader: Void = PatchShader.warm()
        await packs.loadForLaunch()
        try Task.checkCancellation()
        try await collectionStore.loadForLaunch()
        await place.prepareForLaunch()
        await shader
        try Task.checkCancellation()
        latestPatch?.follow()
        Self.backfillRarity(recorder)
    }

    private func handleURL(_ url: URL) {
        if let token = InviteLink.token(from: url) {
            circles.pendingInvite = token
        } else if let link = PatchLink(url: url) {
            pendingPatch = CardCollection.Patch.Key(speciesID: link.speciesID, setID: link.setID)
        } else {
            Task { await connection.handle(url: url) }
        }
    }

    /// The app with its shared objects, under the launch splash.
    private func root(isUnderSplash: Bool) -> some View {
        RootView(isUnderSplash: isUnderSplash, pendingPatch: $pendingPatch)
            .environment(connection)
            .environment(spike)
            .environment(lens)
            .environment(phoneListening)
            .environment(glassesListening)
            .environment(listening)
            .environment(sounds)
            .environment(journalEdits)
            .environment(account)
            .environment(circles)
            .environment(findOutbox)
            .environment(pushes)
            .environment(places)
            .environment(packs)
            .environment(collectionStore)
            .environment(place)
            .environment(\.warmEngine) { BundledIdentification.warm() }
            .environment(\.frameStore, frames)
            .onAppear {
                let versions = packs.packs.map { "\($0.info.id):\($0.info.version)" }.joined(separator: ", ")
                OSSignposter(subsystem: "com.matthewcelia.mybirdjournal", category: "launch")
                    .emitEvent("Launch context", "sightings: \(collectionStore.collection.sightingCount, privacy: .public); packs: \(versions, privacy: .public)")
            }
    }
}

/// The window's content, with the two things at this level that change: the launch splash going, and the appearance from Settings.
private struct AppSurface<Root: View>: View {
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system
    @State private var ready = false
    @State private var error: String?
    @State private var attempt = 0
    @State private var launchPermitted = false
    let prepare: () async throws -> Void
    let openURL: (URL) -> Void
    @ViewBuilder let root: (_ isUnderSplash: Bool) -> Root

    private var waitsForTestSignal: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "launchWaitForTap") && !launchPermitted
        #else
        false
        #endif
    }

    var body: some View {
        ZStack {
            if ready {
                root(false)
                    .onAppear {
                        OSSignposter(subsystem: "com.matthewcelia.mybirdjournal", category: "launch")
                            .emitEvent("Journal interactive")
                    }
            } else {
                LaunchLoadingView(error: error, continueLoading: waitsForTestSignal ? {
                    launchPermitted = true
                    attempt += 1
                } : nil) { attempt += 1 }
            }
        }
        .preferredColorScheme(appearance.colorScheme)
        .onAppear {
            OSSignposter(subsystem: "com.matthewcelia.mybirdjournal", category: "launch")
                .emitEvent("Launch surface appeared")
        }
        .onOpenURL(perform: openURL)
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL { openURL(url) }
        }
        .task(id: attempt) {
            guard !ready, !waitsForTestSignal else { return }
            let signposter = OSSignposter(subsystem: "com.matthewcelia.mybirdjournal", category: "launch")
            let interval = signposter.beginInterval("Stores ready")
            defer { signposter.endInterval("Stores ready", interval) }
            do {
                error = nil
                try await prepare()
                try Task.checkCancellation()
                ready = true
            } catch is CancellationError {
                return
            } catch {
                self.error = "Your journal couldn’t be opened. Try again."
                Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "launch").error("launch failed: \(error.localizedDescription)")
            }
        }
    }
}
