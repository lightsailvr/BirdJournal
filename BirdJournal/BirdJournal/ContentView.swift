import Album
import Identification
import LensSession
import Pack
import SwiftData
import SwiftUI

/// The phone screen: listening, the album (#11), glasses status, the phase A screens, settings with the species pack
/// and the credits, and one fact per module.
struct ContentView: View {
    @Query private var sightings: [Sighting]
    @State private var path: [Screen] = []

    private let planner = WindowPlanner()

    enum Screen: Hashable {
        case glassesListening
        case phoneListening
        case audioSpike
        case lens
        case speciesPack
        case species(id: String)
        case album
        case sighting(id: PersistentIdentifier)
        case settings
        case credits
        case modelLicense(fileName: String)
        case packLicense
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section("Listen") {
                    NavigationLink("Listen with the glasses", value: Screen.glassesListening)
                    NavigationLink("Listen with the phone", value: Screen.phoneListening)
                }

                Section("Album") {
                    NavigationLink(value: Screen.album) {
                        LabeledContent("Sightings", value: "\(sightings.count)")
                    }
                }

                GlassesSection()

                Section("Glasses") {
                    NavigationLink("Lens", value: Screen.lens)
                    NavigationLink("Audio spike", value: Screen.audioSpike)
                }

                Section {
                    NavigationLink("Settings", value: Screen.settings)
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
                case .glassesListening: GlassesListeningView()
                case .phoneListening: PhoneListeningView()
                case .audioSpike: SpikeView()
                case .lens: LensSessionView()
                case .speciesPack: SpeciesPackView()
                case .species(let id):
                    if let pack = BundledPack.pack, let species = pack.species.first(where: { $0.id == id }) {
                        SpeciesDetailView(pack: pack, species: species)
                    }
                case .album: AlbumView()
                case .sighting(let id): SightingDetailView(id: id)
                case .settings: SettingsView()
                case .credits: CreditsView()
                case .modelLicense(let fileName):
                    LicenseTextView(title: fileName) { try ModelCredits.licenseText(fileName: fileName) }
                case .packLicense:
                    LicenseTextView(title: "Pack license") { try BundledPack.loaded.get().info.licenseText }
                }
            }
            #if DEBUG
            .modifier(AutoMockLens(path: $path))
            .modifier(AutoPhoneListening(path: $path))
            .modifier(AutoSpeciesPack(path: $path))
            .modifier(AutoAlbum(path: $path))
            .modifier(AutoCredits(path: $path))
            #endif
        }
    }
}

#if DEBUG
/// Launch with `-autoMockLens YES` to pair the mock, open the lens screen, start the pages, hear three fake
/// species and walk to the second species card: a screenshot of the simulator then shows the mock lens without any taps.
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
            let sequence = UserDefaults.standard.string(forKey: "autoMockLensInputs") ?? "navLeft navLeft"
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
    @Environment(ListeningSession.self) private var session
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
            if let species = BundledPack.pack?.species(scientificName: value) { path.append(.species(id: species.id)) }
        }
    }
}
#endif

#if DEBUG
/// Launch with `-autoAlbum YES` to open the album, `-autoAlbum seed` to first add three sightings with generated
/// frames (a ring at the center of a 640 × 480 frame with a black border, so the 2x crop is visible as such), or
/// `-autoAlbum seed-detail` to also open the newest one; with `-inMemoryAlbum YES` the seeds never touch the album
/// on disk. For simulator screenshots of issue #11.
private struct AutoAlbum: ViewModifier {
    @Environment(\.modelContext) private var context
    @Environment(\.frameStore) private var frameStore
    @Binding var path: [ContentView.Screen]

    func body(content: Content) -> some View {
        content.task {
            guard let value = UserDefaults.standard.string(forKey: "autoAlbum") else { return }
            if value.hasPrefix("seed") { seed() }
            path = [.album]
            if value == "seed-detail", let newest = try? context.fetch(Sighting.newestFirst()).first {
                path.append(.sighting(id: newest.persistentModelID))
            }
        }
    }

    private func seed() {
        let griffithPark = Coordinate(latitude: 34.1365, longitude: -118.2942, accuracy: 15)
        let seeds: [(label: String, minutesAgo: Double, location: Coordinate?, confidence: Double)] = [
            ("Sayornis nigricans_Black Phoebe", 3, griffithPark, 0.82),
            ("Calypte anna_Anna's Hummingbird", 90, griffithPark, 0.64),
            ("Turdus migratorius_American Robin", 1_500, nil, 0.71),
        ]
        for seed in seeds {
            let frame = try? frameStore?.write(jpeg: Self.frameJPEG())
            context.insert(Sighting(
                speciesID: seed.label,
                confirmedAt: Date.now.addingTimeInterval(-seed.minutesAgo * 60),
                location: seed.location,
                soundConfidence: seed.confidence,
                frameImagePath: frame,
                source: .glasses
            ))
        }
        try? context.save()
    }

    /// A stand-in camera frame: a green field with a small ring at the center.
    private static func frameJPEG() -> Data {
        let size = CGSize(width: 640, height: 480)
        let image = UIGraphicsImageRenderer(size: size).image { renderer in
            UIColor(red: 0.35, green: 0.55, blue: 0.3, alpha: 1).setFill()
            renderer.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setStroke()
            let ring = UIBezierPath(ovalIn: CGRect(x: size.width / 2 - 24, y: size.height / 2 - 24, width: 48, height: 48))
            ring.lineWidth = 6
            ring.stroke()
            UIColor.black.setStroke()
            let border = UIBezierPath(rect: CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 8))
            border.lineWidth = 16
            border.stroke()
        }
        return image.jpegData(compressionQuality: 0.85) ?? Data()
    }
}
#endif

#if DEBUG
/// Launch with `-autoCredits YES` to open Settings then Credits, for simulator screenshots of issue #11.
private struct AutoCredits: ViewModifier {
    @Binding var path: [ContentView.Screen]

    func body(content: Content) -> some View {
        content.task {
            guard UserDefaults.standard.bool(forKey: "autoCredits") else { return }
            path = [.settings, .credits]
        }
    }
}
#endif
