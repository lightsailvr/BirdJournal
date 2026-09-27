import Album
import Identification
import LensSession
import Pack
import SwiftData
import SwiftUI

/// The phone screen: listening, the album (#11), glasses status, the phase A screens, settings with the species packs
/// (#13) and the credits, and one fact per module.
struct ContentView: View {
    @Query private var sightings: [Sighting]
    @Environment(PackLibrary.self) private var library
    @State private var path: [Screen] = []

    private let planner = WindowPlanner()

    enum Screen: Hashable {
        case glassesListening
        case phoneListening
        case audioSpike
        case lens
        case packs
        case pack(id: String)
        case species(packID: String, id: String)
        case album
        case sighting(id: PersistentIdentifier)
        case settings
        case credits
        case modelLicense(fileName: String)
        case packLicense(id: String)
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
                    LabeledContent("Pack", value: library.packs.isEmpty ? "\(PackIndex.bundledPackID) missing" : library.packs.map { "\($0.info.id) v\($0.info.version), \($0.species.count) species" }.joined(separator: "; "))
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
                case .packs: PacksView()
                case .pack(let id):
                    if let pack = library.pack(id: id) {
                        SpeciesPackView(pack: pack)
                    } else {
                        ContentUnavailableView("Pack removed", systemImage: "bird")
                    }
                case .species(let packID, let id):
                    if let pack = library.pack(id: packID), let species = pack.species.first(where: { $0.id == id }) {
                        SpeciesDetailView(pack: pack, species: species)
                    } else {
                        ContentUnavailableView("Pack removed", systemImage: "bird")
                    }
                case .album: AlbumView()
                case .sighting(let id): SightingDetailView(id: id)
                case .settings: SettingsView()
                case .credits: CreditsView()
                case .modelLicense(let fileName):
                    LicenseTextView(title: fileName) { try ModelCredits.licenseText(fileName: fileName) }
                case .packLicense(let id):
                    LicenseTextView(title: "Pack license") {
                        guard let pack = library.pack(id: id) else { throw PackError.notInstalled(id) }
                        return pack.info.licenseText
                    }
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
/// Launch with `-autoSpeciesPack YES` to open the species packs screen, `-autoSpeciesPack list` to open the bundled
/// pack's species list, or `-autoSpeciesPack <scientific name>` to open that species' detail in the first pack that
/// has it, for simulator screenshots of the packs. `-autoDownloadPack <id>` (with `-packIndexURL <url>`, see
/// `PackLibrary.forApp`) opens the packs screen and downloads that pack from the index, the way a tap on Download
/// would, so the download path can be watched on the simulator without a real release.
private struct AutoSpeciesPack: ViewModifier {
    @Environment(PackLibrary.self) private var library
    @Binding var path: [ContentView.Screen]

    func body(content: Content) -> some View {
        content.task {
            if let id = UserDefaults.standard.string(forKey: "autoDownloadPack") {
                path = [.settings, .packs]
                await library.refreshIndex()
                if let descriptor = library.index?.descriptor(id: id) { library.startDownload(descriptor) }
                return
            }
            guard let value = UserDefaults.standard.string(forKey: "autoSpeciesPack") else { return }
            path = [.settings, .packs]
            if value == "list", let bundled = library.bundled {
                path.append(.pack(id: bundled.info.id))
            } else if let found = library.species(scientificName: value) {
                path.append(.pack(id: found.pack.info.id))
                path.append(.species(packID: found.pack.info.id, id: found.species.id))
            }
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
