import Album
import Identification
import LensSession
import Pack
import SwiftData
import SwiftUI

/// Placeholder phone screen until phase D: phone listening, glasses status, the phase A screens, and one fact per module.
struct ContentView: View {
    @Query private var sightings: [Sighting]
    @State private var path: [Screen] = []

    private let planner = WindowPlanner()
    private let navigation = LensNavigation()

    enum Screen: Hashable {
        case phoneListening
        case audioSpike
        case lensCard
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section("Listen") {
                    NavigationLink("Listen with the phone", value: Screen.phoneListening)
                }

                GlassesSection()

                Section("Phase A") {
                    NavigationLink("Audio spike", value: Screen.audioSpike)
                    NavigationLink("Lens card", value: Screen.lensCard)
                }

                Section("Modules") {
                    LabeledContent("Identification", value: "\(planner.sampleRate) Hz, \(planner.samplesPerWindow) samples per window")
                    LabeledContent("LensSession", value: String(describing: navigation.page))
                    LabeledContent("Pack", value: PackIndex.bundledPackID)
                    LabeledContent("Album", value: "\(sightings.count) sightings")
                }
            }
            .navigationTitle("BirdJournal")
            .navigationDestination(for: Screen.self) { screen in
                switch screen {
                case .phoneListening: PhoneListeningView()
                case .audioSpike: SpikeView()
                case .lensCard: LensSessionView()
                }
            }
            #if DEBUG
            .modifier(AutoMockLens(path: $path))
            .modifier(AutoPhoneListening(path: $path))
            #endif
        }
    }
}

#if DEBUG
/// Launch with `-autoMockLens YES` to pair the mock, open the lens screen, start the card and inject a few
/// gestures: a screenshot of the simulator then shows the mock lens without any taps.
private struct AutoMockLens: ViewModifier {
    @Environment(GlassesConnection.self) private var connection
    @Environment(GlassesLensSession.self) private var lens
    @Binding var path: [ContentView.Screen]

    func body(content: Content) -> some View {
        content.task {
            guard UserDefaults.standard.bool(forKey: "autoMockLens") else { return }
            connection.pairMockGlasses()
            path = [.lensCard]
            await lens.start()
            for input in [GlassesConnection.MockInput.navLeft, .navDown, .select] {
                try? await Task.sleep(for: .seconds(1))
                connection.injectMockInput(input)
            }
        }
    }
}
#endif

#if DEBUG
/// Launch with `-autoPhoneListening YES` (or a WAV path, see `BirdJournalApp`) to open the phone listening screen
/// and start a session, for screenshots and simulator checks of the location and model paths.
private struct AutoPhoneListening: ViewModifier {
    @Environment(PhoneListeningSession.self) private var session
    @Binding var path: [ContentView.Screen]

    func body(content: Content) -> some View {
        content.task {
            guard UserDefaults.standard.object(forKey: "autoPhoneListening") != nil else { return }
            path = [.phoneListening]
            await session.start()
        }
    }
}
#endif
