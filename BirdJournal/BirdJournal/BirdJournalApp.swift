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
    @State private var connection: GlassesConnection
    @State private var spike: SpikeRecorder
    @State private var lens: GlassesLensSession
    @State private var phoneListening: ListeningSession
    @State private var glassesListening: GlassesListeningSession
    @State private var listening: ListeningCoordinator
    @State private var sounds: ReferenceSounds
    @State private var places: PlaceNames
    @State private var packs: PackLibrary
    @State private var journalEdits: JournalEdits
    @State private var account: AccountSession
    @State private var circles: CircleStore
    @State private var art: ArtJobs
    @Environment(\.scenePhase) private var scenePhase
    @State private var findOutbox: FindOutbox
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system
    @State private var showingSplash = true
    private let album: ModelContainer
    private let frames: FrameStore

    init() {
        do {
            try Wearables.configure()
        } catch {
            Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "glasses")
                .error("Wearables.configure failed: \(error.localizedDescription)")
        }
        JournalFont.applyNavigationBarAppearance()
        let connection = GlassesConnection()
        let album = Self.makeAlbum()
        let frames = Self.makeFrameStore()
        let packs = PackLibrary.forApp()
        let levels = LevelSink()
        // The reference clips the profile plays (issue #41) are silenced in whichever run is listening.
        let suppression = AudioSuppression()
        let recorder = SightingRecorder(container: album, frames: frames, rarity: BundledIdentification.rarityReader())
        recorder.sets = { packs.cardSets }
        Self.backfillRarity(recorder)
        let sightings = RunSightings(recorder: recorder)
        let places = PlaceNames()
        sightings.captioner = Self.makeCaptioner(packs: packs, places: places)
        _places = State(initialValue: places)
        let phone = Self.makePhoneListeningSession(levels: levels, suppression: suppression)
        let glasses = Self.makeGlassesListeningSession(connection: connection, recorder: recorder, sightings: sightings, packs: packs, levels: levels, suppression: suppression)
        let listening = ListeningCoordinator(
            phone: phone, glasses: glasses, sightings: sightings, levels: levels,
            defaultSource: connection.devices.isEmpty ? .phone : .glasses
        )
        self.album = album
        self.frames = frames
        let account = AccountSession.forApp()
        _account = State(initialValue: account)
        let circles = CircleStore.forApp(account: account)
        _circles = State(initialValue: circles)
        let art = Self.makeArtJobs(account: account, frames: frames, album: album, packs: packs)
        sightings.artJobs = art
        _art = State(initialValue: art)
        // Finds (issue #62): adds made while signed in and sharing reach the birder's circles.
        let findOutbox = FindOutbox.forApp(account: account, client: circles.client, album: album, packs: packs, places: places)
        sightings.findOutbox = findOutbox
        _findOutbox = State(initialValue: findOutbox)
        _connection = State(initialValue: connection)
        _spike = State(initialValue: SpikeRecorder(connection: connection))
        _packs = State(initialValue: packs)
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
        _sounds = State(initialValue: sounds)
        let journalEdits = JournalEdits(container: album, frames: frames)
        journalEdits.findOutbox = findOutbox
        _journalEdits = State(initialValue: journalEdits)
    }

    /// The album on disk. Failing to open it is a broken install, not a field condition, so it traps like the
    /// `.modelContainer(for:)` modifier it replaces did, rather than silently saving sightings to memory. In debug
    /// builds `-inMemoryAlbum YES` keeps the album in memory, so screenshot runs can seed it without leaving a trace.
    private static func makeAlbum() -> ModelContainer {
        var inMemory = false
        #if DEBUG
        inMemory = UserDefaults.standard.bool(forKey: "inMemoryAlbum")
        #endif
        do {
            return try AlbumSchema.makeContainer(inMemory: inMemory)
        } catch {
            fatalError("album store unavailable: \(error)")
        }
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

    /// Scene art (issue #68): each add's job carries whether its card is Legendary and its set's edition, read from the
    /// collection at the moment the job is created.
    private static func makeArtJobs(account: AccountSession, frames: FrameStore, album: ModelContainer, packs: PackLibrary) -> ArtJobs {
        let art = ArtJobs.forApp(account: account, frames: frames, container: album)
        art.cardFacts = { sighting in
            let collection = packs.collection(of: (try? album.mainContext.fetch(FetchDescriptor<Sighting>())) ?? [])
            return ArtJobs.CardFacts(legendary: collection.isLegendary(sighting.identifier), edition: collection.placement(of: sighting.identifier)?.setID)
        }
        return art
    }

    /// Sightings saved before rarity existed get theirs once (issue #52), after launch and with the geomodel read off
    /// the main actor. The debug in-memory album is skipped: it would mark the album on disk as done.
    private static func backfillRarity(_ recorder: SightingRecorder) {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "inMemoryAlbum") { return }
        #endif
        Task { await recorder.backfillRarity() }
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
        GlassesListeningSession(
            connection: connection,
            recorder: recorder,
            sightings: sightings,
            makeSource: { session in
                GlassesAudioSource(lease: .shared(session), sampleRate: .rate44100, onLevel: { levels.level = $0 })
            },
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
            let location: any LocationProvider = UserDefaults.standard.string(forKey: "autoLocation") == "denied" ? DeniedLocationProvider() : CoreLocationProvider()
            return ListeningSession(makeSource: { MeteredAudioSource(PacedAudioSource(WAVFileAudioSource(url: URL(fileURLWithPath: path))), onLevel: meter) }, location: location, suppression: suppression)
        }
        #endif
        return ListeningSession(makeSource: { MeteredAudioSource(PhoneMicAudioSource(), onLevel: meter) }, suppression: suppression)
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                root
                if showingSplash {
                    LaunchSplash { withAnimation(.easeInOut(duration: 0.5)) { showingSplash = false } }
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .preferredColorScheme(appearance.colorScheme)
        }
        .modelContainer(album)
    }

    /// The app with its shared objects, under the launch splash.
    private var root: some View {
        RootView()
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
            .environment(art)
            .environment(findOutbox)
            .environment(places)
            .environment(packs)
            .environment(\.frameStore, frames)
            // Art jobs are polled on launch and whenever the app comes back (issue #68).
            .task { await art.refresh() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await art.refresh() } }
            }
            .onOpenURL { url in
                // An invite link (issue #61) arrives here as a universal link; everything else is the toolkit's.
                if let token = InviteLink.token(from: url) {
                    circles.pendingInvite = token
                } else {
                    Task { await connection.handle(url: url) }
                }
            }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                if let url = activity.webpageURL, let token = InviteLink.token(from: url) {
                    circles.pendingInvite = token
                }
            }
    }
}
