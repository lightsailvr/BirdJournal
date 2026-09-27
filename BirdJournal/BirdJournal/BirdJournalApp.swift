import Album
import MWDATCore
import OSLog
import SwiftData
import SwiftUI

@main
struct BirdJournalApp: App {
    @State private var connection: GlassesConnection
    @State private var spike: SpikeRecorder
    @State private var lens: GlassesLensSession

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
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(connection)
                .environment(spike)
                .environment(lens)
                .onOpenURL { url in
                    Task { await connection.handle(url: url) }
                }
        }
        .modelContainer(for: AlbumSchema.models)
    }
}
