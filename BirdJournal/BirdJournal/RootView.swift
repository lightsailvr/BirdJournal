import Album
import Identification
import Pack
import SwiftData
import SwiftUI

/// Where the app can go from any tab (issue #28). One destination table serves every tab's stack, so a bird profile
/// opens the same way from the guide, the journal and a review.
enum Route: Hashable {
    case species(scientificName: String, commonName: String)
    case speciesCredits(scientificName: String)
    case sighting(PersistentIdentifier)
    /// One card, front first (issue #52); opened from a species gallery, it browses that gallery's filtered order
    /// (issue #53).
    case card(PersistentIdentifier, browse: GalleryBrowse? = nil)
    /// One species' cards (issue #53), marking `selected` when a card's All encounters opened it.
    case gallery(scientificName: String, commonName: String, selected: UUID? = nil)
    /// One set's species in collector order, silhouettes for the uncollected (issue #54).
    case set(id: String)
    case packs
    case pack(id: String)
    case credits
    case modelLicense(fileName: String)
    case packLicense(id: String)
    case settings
    case appIcon
}

extension View {
    /// The destinations for every `Route`, on a navigation stack.
    func appDestinations() -> some View {
        navigationDestination(for: Route.self) { route in
            RouteDestination(route: route)
        }
    }
}

private struct RouteDestination: View {
    @Environment(PackLibrary.self) private var library
    let route: Route

    var body: some View {
        switch route {
        case .species(let scientificName, let commonName):
            BirdProfileView(scientificName: scientificName, commonName: commonName)
        case .speciesCredits(let scientificName):
            SpeciesCreditsView(scientificName: scientificName)
        case .sighting(let id):
            SightingDetailView(id: id)
        case .card(let id, let browse):
            CardDetailView(id: id, browse: browse)
        case .gallery(let scientificName, let commonName, let selected):
            SpeciesGalleryView(scientificName: scientificName, commonName: commonName, selected: selected)
        case .set(let id):
            SetView(id: id)
        case .packs:
            BirdPacksView()
        case .pack(let id):
            PackDetailView(id: id)
        case .credits:
            CreditsView()
        case .modelLicense(let fileName):
            LicenseTextView(title: fileName) { try ModelCredits.licenseText(fileName: fileName) }
        case .packLicense(let id):
            LicenseTextView(title: "Pack license") {
                guard let pack = library.pack(id: id) else { throw PackError.notInstalled(id) }
                return pack.info.licenseText
            }
        case .settings:
            SettingsView()
        case .appIcon:
            AppIconView()
        }
    }
}

extension EnvironmentValues {
    /// Opens the Journal tab on the Cards view: the Legendary reveal's "Back to my collection" (issue #51).
    @Entry var openCollection: @MainActor () -> Void = {}
    /// Opens the Listen tab: a species gallery with no cards yet (issue #53).
    @Entry var openListen: @MainActor () -> Void = {}
}

/// The three destinations (issue #28): Listen, Journal and Field Guide, with the compact listening strip above the
/// tab bar while a run is on and another tab is showing.
struct RootView: View {
    enum Tab: String, Hashable {
        case listen, journal, guide
    }

    @Environment(ListeningCoordinator.self) private var run
    @Environment(PackLibrary.self) private var library
    @State private var tab: Tab = .listen
    @State private var journalMode: JournalView.Mode = .cards
    @State private var listenPath = NavigationPath()
    @State private var journalPath = NavigationPath()
    @State private var guidePath = NavigationPath()
    #if DEBUG
    @State private var showingDeveloper = false
    #endif

    var body: some View {
        TabView(selection: $tab) {
            SwiftUI.Tab("Listen", systemImage: "waveform", value: Tab.listen) {
                NavigationStack(path: $listenPath) {
                    ListenView()
                        .appDestinations()
                }
            }
            SwiftUI.Tab("Journal", systemImage: "book", value: Tab.journal) {
                NavigationStack(path: $journalPath) {
                    JournalView(mode: $journalMode)
                        .appDestinations()
                }
            }
            SwiftUI.Tab("Field Guide", systemImage: "bird", value: Tab.guide) {
                NavigationStack(path: $guidePath) {
                    FieldGuideView()
                        .appDestinations()
                }
            }
        }
        .tabViewBottomAccessory(isEnabled: run.state.isActive && tab != .listen) {
            ListeningAccessory { tab = .listen }
        }
        .tint(Color.moss)
        // Over the tabs and their bars; the run review sheet carries its own, since an add there happens over it.
        .legendaryReveal()
        .environment(\.openCollection) {
            journalMode = .cards
            journalPath = NavigationPath()
            tab = .journal
        }
        .environment(\.openListen) { tab = .listen }
        // The index carries every pack's set (issue #54), so it is fetched at launch, not only on the packs screen;
        // the last good copy stands in meanwhile and offline.
        .task { await library.refreshIndex() }
        #if DEBUG
        .sheet(isPresented: $showingDeveloper) { DeveloperView() }
        .modifier(DebugLaunch(tab: $tab, journalMode: $journalMode, listenPath: $listenPath, journalPath: $journalPath, guidePath: $guidePath, showingDeveloper: $showingDeveloper))
        #endif
    }
}
