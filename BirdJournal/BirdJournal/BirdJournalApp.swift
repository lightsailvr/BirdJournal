import Album
import SwiftData
import SwiftUI

@main
struct BirdJournalApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: AlbumSchema.models)
    }
}
