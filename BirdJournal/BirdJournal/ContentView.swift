import Album
import Identification
import LensSession
import Pack
import SwiftData
import SwiftUI

/// Placeholder phone screen until phase D shows one fact from each module.
struct ContentView: View {
    @Query private var sightings: [Sighting]

    private let planner = WindowPlanner()
    private let navigation = LensNavigation()

    var body: some View {
        NavigationStack {
            List {
                Section("Modules") {
                    LabeledContent("Identification", value: "\(planner.sampleRate) Hz, \(planner.samplesPerWindow) samples per window")
                    LabeledContent("LensSession", value: String(describing: navigation.page))
                    LabeledContent("Pack", value: PackIndex.bundledPackID)
                    LabeledContent("Album", value: "\(sightings.count) sightings")
                }
            }
            .navigationTitle("BirdJournal")
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(try! AlbumSchema.makeContainer(inMemory: true))
}
