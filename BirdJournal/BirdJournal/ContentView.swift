import Album
import Identification
import LensSession
import Pack
import SwiftData
import SwiftUI

/// Placeholder phone screen until phase D: phone listening, glasses status, the phase A screens, the bundled species
/// pack, and one fact per module.
struct ContentView: View {
    @Query private var sightings: [Sighting]
    @State private var path: [Screen] = []

    private let planner = WindowPlanner()

    enum Screen: Hashable {
        case phoneListening
        case audioSpike
        case lens
        case speciesPack
        case species(PackSpecies)
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section("Listen") {
                    NavigationLink("Listen with the phone", value: Screen.phoneListening)
                }

                GlassesSection()

                Section("Glasses") {
                    NavigationLink("Lens", value: Screen.lens)
                    NavigationLink("Audio spike", value: Screen.audioSpike)
                }

                Section("Species pack") {
                    NavigationLink(BundledPack.pack?.info.name ?? "Species", value: Screen.speciesPack)
                }

                Section("Modules") {
                    LabeledContent("Identification", value: "\(planner.sampleRate) Hz, \(planner.samplesPerWindow) samples per window")
                    LabeledContent("LensSession", value: "\(LensCardRenderer.wordBudget) words per page")
                    LabeledContent("Pack", value: BundledPack.pack.map { "\($0.info.id) v\($0.info.version), \($0.species.count) species" } ?? "\(PackIndex.bundledPackID) missing")
                    LabeledContent("Album", value: "\(sightings.count) sightings")
                }
            }
            .navigationTitle("BirdJournal")
            .navigationDestination(for: Screen.self) { screen in
                switch screen {
                case .phoneListening: PhoneListeningView()
                case .audioSpike: SpikeView()
                case .lens: LensSessionView()
                case .speciesPack: SpeciesPackView()
                case .species(let species):
                    if let pack = BundledPack.pack { SpeciesDetailView(pack: pack, species: species) }
                }
            }
            #if DEBUG
            .modifier(AutoMockLens(path: $path))
            .modifier(AutoPhoneListening(path: $path))
            .modifier(AutoSpeciesPack(path: $path))
            #endif
        }
    }
}

#if DEBUG
/// Launch with `-autoMockLens YES` to pair the mock, open the lens screen, start the pages, hear three fake
/// species and walk to a description page: a screenshot of the simulator then shows the mock lens without any taps.
/// `-autoMockLensInputs "navLeft select"` walks a different sequence (mock input names, one second apart).
private struct AutoMockLens: ViewModifier {
    @Environment(GlassesConnection.self) private var connection
    @Environment(GlassesLensSession.self) private var lens
    @Binding var path: [ContentView.Screen]

    func body(content: Content) -> some View {
        content.task {
            guard UserDefaults.standard.bool(forKey: "autoMockLens") else { return }
            connection.pairMockGlasses()
            path = [.lens]
            await lens.start()
            lens.update(with: FakeLensStack.stack(count: 3))
            let sequence = UserDefaults.standard.string(forKey: "autoMockLensInputs") ?? "navLeft navLeft navDown"
            let inputs = sequence.split(whereSeparator: \.isWhitespace).compactMap { name in
                GlassesConnection.MockInput.allCases.first { String(describing: $0) == name }
            }
            for input in inputs {
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

#if DEBUG
/// Launch with `-autoSpeciesPack YES` to open the species pack screen, or `-autoSpeciesPack <scientific name>` to
/// open that species' detail, for simulator screenshots of the bundled pack.
private struct AutoSpeciesPack: ViewModifier {
    @Binding var path: [ContentView.Screen]

    func body(content: Content) -> some View {
        content.task {
            guard let value = UserDefaults.standard.string(forKey: "autoSpeciesPack") else { return }
            path = [.speciesPack]
            if let species = BundledPack.pack?.species(scientificName: value) { path.append(.species(species)) }
        }
    }
}
#endif
