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
    @State private var phoneListening: PhoneListeningSession

    init() {
        do {
            try Wearables.configure()
        } catch {
            Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "glasses")
                .error("Wearables.configure failed: \(error.localizedDescription)")
        }
        let connection = GlassesConnection()
        _connection = State(initialValue: connection)
        _spike = State(initialValue: SpikeRecorder(connection: connection))
        _lens = State(initialValue: GlassesLensSession(connection: connection))
        _phoneListening = State(initialValue: Self.makePhoneListeningSession())
    }

    /// The phone listening session over the real microphone. In debug builds, `-autoPhoneListening <path.wav>`
    /// feeds that file instead, so the screen can be checked on the simulator, whose audio input is not available.
    private static func makePhoneListeningSession() -> PhoneListeningSession {
        #if DEBUG
        if let path = UserDefaults.standard.string(forKey: "autoPhoneListening"), path.hasSuffix(".wav") {
            return PhoneListeningSession(makeSource: { WAVFileAudioSource(url: URL(fileURLWithPath: path)) })
        }
        #endif
        return PhoneListeningSession()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(connection)
                .environment(spike)
                .environment(lens)
                .environment(phoneListening)
                .onOpenURL { url in
                    Task { await connection.handle(url: url) }
                }
        }
        .modelContainer(for: AlbumSchema.models)
    }
}
