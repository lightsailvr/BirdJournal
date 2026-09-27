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

    /// The album on disk. A store that cannot be opened is not worth crashing the field app over: sightings then go
    /// to memory for the run and the error is logged.
    private static func makeAlbum() -> ModelContainer {
        do {
            return try AlbumSchema.makeContainer()
        } catch {
            Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "album")
                .error("album store unavailable, using memory: \(error.localizedDescription)")
            return try! AlbumSchema.makeContainer(inMemory: true) // In-memory stores do not fail to open.
        }
    }

    /// The lens session over the bundled species pack: photo and description pages come from the pack, and a
    /// species the pack lacks shows by name alone.
    private static func makeLensSession(connection: GlassesConnection) -> GlassesLensSession {
        GlassesLensSession(connection: connection, profile: BundledPack.profile(for:), image: BundledPack.image(for:))
    }

    /// The whole loop on the glasses (issue #9), writing sightings to the album and frames beside it.
    private static func makeGlassesListeningSession(connection: GlassesConnection, album: ModelContainer) -> GlassesListeningSession {
        let frames = (try? FrameStore.applicationSupport()) ?? FrameStore(directory: URL.temporaryDirectory.appending(path: "Frames"))
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
