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
    @State private var places = PlaceNames()
    @State private var packs: PackLibrary
    @State private var journalEdits: JournalEdits
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
        let recorder = SightingRecorder(container: album, frames: frames)
        let sightings = RunSightings(recorder: recorder)
        let phone = Self.makePhoneListeningSession(levels: levels)
        let glasses = Self.makeGlassesListeningSession(connection: connection, recorder: recorder, sightings: sightings, packs: packs, levels: levels)
        self.album = album
        self.frames = frames
        _connection = State(initialValue: connection)
        _spike = State(initialValue: SpikeRecorder(connection: connection))
        _packs = State(initialValue: packs)
        _lens = State(initialValue: Self.makeLensSession(connection: connection, packs: packs))
        _phoneListening = State(initialValue: phone)
        _glassesListening = State(initialValue: glasses)
        _listening = State(initialValue: ListeningCoordinator(
            phone: phone, glasses: glasses, sightings: sightings, levels: levels,
            defaultSource: connection.devices.isEmpty ? .phone : .glasses
        ))
        _journalEdits = State(initialValue: JournalEdits(container: album, frames: frames))
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
    private static func makeGlassesListeningSession(connection: GlassesConnection, recorder: SightingRecorder, sightings: RunSightings, packs: PackLibrary, levels: LevelSink) -> GlassesListeningSession {
        GlassesListeningSession(
            connection: connection,
            recorder: recorder,
            sightings: sightings,
            makeSource: { session in
                GlassesAudioSource(lease: .shared(session), sampleRate: .rate44100, onLevel: { levels.level = $0 })
            },
            profile: { packs.profile(for: $0) },
            image: { packs.image(for: $0) }
        )
    }

    /// The phone listening session over the real microphone, metered for the waveform. In debug builds,
    /// `-autoPhoneListening <path.wav>` feeds that file instead, so the screen can be checked on the simulator, whose
    /// audio input is not available.
    private static func makePhoneListeningSession(levels: LevelSink) -> ListeningSession {
        let meter: @Sendable (AudioLevel) -> Void = { levels.level = $0 }
        #if DEBUG
        if let path = UserDefaults.standard.string(forKey: "autoPhoneListening"), path.hasSuffix(".wav") {
            // Paced like a microphone, so the Listen tab's live state can be seen and screenshotted on the simulator.
            return ListeningSession(makeSource: { MeteredAudioSource(PacedAudioSource(WAVFileAudioSource(url: URL(fileURLWithPath: path))), onLevel: meter) })
        }
        #endif
        return ListeningSession(makeSource: { MeteredAudioSource(PhoneMicAudioSource(), onLevel: meter) })
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
            .environment(journalEdits)
            .environment(places)
            .environment(packs)
            .environment(\.frameStore, frames)
            .onOpenURL { url in
                Task { await connection.handle(url: url) }
            }
    }
}
