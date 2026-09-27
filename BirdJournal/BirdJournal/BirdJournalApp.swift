import Album
import Identification
import MWDATCore
import OSLog
import SwiftData
import SwiftUI

@main
struct BirdJournalApp: App {
    @State private var connection: GlassesConnection
    @State private var spike: SpikeRecorder
    @State private var lens: GlassesLensSession
    @State private var phoneListening: ListeningSession
    @State private var glassesListening: GlassesListeningSession
    @State private var places = PlaceNames()
    private let album: ModelContainer
    private let frames: FrameStore

    init() {
        do {
            try Wearables.configure()
        } catch {
            Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "glasses")
                .error("Wearables.configure failed: \(error.localizedDescription)")
        }
        let connection = GlassesConnection()
        let album = Self.makeAlbum()
        let frames = Self.makeFrameStore()
        self.album = album
        self.frames = frames
        _connection = State(initialValue: connection)
        _spike = State(initialValue: SpikeRecorder(connection: connection))
        _lens = State(initialValue: Self.makeLensSession(connection: connection))
        _phoneListening = State(initialValue: Self.makePhoneListeningSession())
        _glassesListening = State(initialValue: Self.makeGlassesListeningSession(connection: connection, album: album, frames: frames))
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

    /// The lens session over the bundled species pack: the species cards' photos and text come from the pack,
    /// and a species the pack lacks shows by name alone.
    private static func makeLensSession(connection: GlassesConnection) -> GlassesLensSession {
        GlassesLensSession(connection: connection, profile: BundledPack.profile(for:), image: BundledPack.image(for:))
    }

    /// The whole loop on the glasses (issue #9), writing sightings to the album and frames beside it.
    private static func makeGlassesListeningSession(connection: GlassesConnection, album: ModelContainer, frames: FrameStore) -> GlassesListeningSession {
        GlassesListeningSession(
            connection: connection,
            recorder: SightingRecorder(container: album, frames: frames),
            profile: BundledPack.profile(for:),
            image: BundledPack.image(for:)
        )
    }

    /// The phone listening session over the real microphone. In debug builds, `-autoPhoneListening <path.wav>`
    /// feeds that file instead, so the screen can be checked on the simulator, whose audio input is not available.
    private static func makePhoneListeningSession() -> ListeningSession {
        #if DEBUG
        if let path = UserDefaults.standard.string(forKey: "autoPhoneListening"), path.hasSuffix(".wav") {
            return ListeningSession(makeSource: { WAVFileAudioSource(url: URL(fileURLWithPath: path)) })
        }
        #endif
        return ListeningSession()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(connection)
                .environment(spike)
                .environment(lens)
                .environment(phoneListening)
                .environment(glassesListening)
                .environment(places)
                .environment(\.frameStore, frames)
                .onOpenURL { url in
                    Task { await connection.handle(url: url) }
                }
        }
        .modelContainer(album)
    }
}
