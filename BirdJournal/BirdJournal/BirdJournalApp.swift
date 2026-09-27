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
    private let album: ModelContainer

    init() {
        do {
            try Wearables.configure()
        } catch {
            Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "glasses")
                .error("Wearables.configure failed: \(error.localizedDescription)")
        }
        let connection = GlassesConnection()
        let album = Self.makeAlbum()
        self.album = album
        _connection = State(initialValue: connection)
        _spike = State(initialValue: SpikeRecorder(connection: connection))
        _lens = State(initialValue: Self.makeLensSession(connection: connection))
        _phoneListening = State(initialValue: Self.makePhoneListeningSession())
        _glassesListening = State(initialValue: Self.makeGlassesListeningSession(connection: connection, album: album))
    }

    /// The album on disk. Failing to open it is a broken install, not a field condition, so it traps like the
    /// `.modelContainer(for:)` modifier it replaces did, rather than silently saving sightings to memory.
    private static func makeAlbum() -> ModelContainer {
        do {
            return try AlbumSchema.makeContainer()
        } catch {
            fatalError("album store unavailable: \(error)")
        }
    }

    /// The lens session over the bundled species pack: the species cards' photos and text come from the pack,
    /// and a species the pack lacks shows by name alone.
    private static func makeLensSession(connection: GlassesConnection) -> GlassesLensSession {
        GlassesLensSession(connection: connection, profile: BundledPack.profile(for:), image: BundledPack.image(for:))
    }

    /// The whole loop on the glasses (issue #9), writing sightings to the album and frames beside it.
    private static func makeGlassesListeningSession(connection: GlassesConnection, album: ModelContainer) -> GlassesListeningSession {
        let frames: FrameStore
        do {
            frames = try FrameStore.applicationSupport()
        } catch {
            // iOS purges tmp, so frames saved there can vanish; the sighting keeps the path and the album shows no image.
            Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "album")
                .error("Application Support unavailable, frames go to tmp: \(error.localizedDescription)")
            frames = FrameStore(directory: URL.temporaryDirectory.appending(path: "Frames", directoryHint: .isDirectory))
        }
        return GlassesListeningSession(
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
                .onOpenURL { url in
                    Task { await connection.handle(url: url) }
                }
        }
        .modelContainer(album)
    }
}
