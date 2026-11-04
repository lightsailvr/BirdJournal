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
    /// One patch, on its page with its paper card behind it (issue #134).
    case patch(CardCollection.Patch.Key)
    /// A patch's sightings, or every sighting of the species.
    case sightings(SightingsScope)
    /// One species' patches across places (issue #134).
    case speciesPatches(scientificName: String, commonName: String)
    /// One set's species in collector order, silhouettes for the uncollected (issue #54).
    case set(id: String)
    case packs
    case pack(id: String)
    case credits
    case modelLicense(fileName: String)
    case packLicense(id: String)
    case settings
    case appIcon
    case account
    /// The tip jar (issue #59).
    case support
    /// A circle's page (issue #61).
    case circle(id: String)
    /// The join screen an invite link opens (issue #61).
    case joinCircle(token: String)
    /// Compare birds with a friend (issue #64).
    case compareBirds(friendID: String, friendName: String)
    /// The accounts the birder blocked, to unblock (issue #71).
    case blockedAccounts
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
        case .patch(let key):
            PatchDetailView(key: key)
        case .sightings(let scope):
            PatchSightingsView(scope: scope)
        case .speciesPatches(let scientificName, let commonName):
            SpeciesPatchesView(scientificName: scientificName, commonName: commonName)
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
        case .account:
            AccountView()
        case .support:
            SupportView()
        case .circle(let id):
            CirclePageView(id: id)
        case .joinCircle(let token):
            JoinCircleView(token: token)
        case .compareBirds(let friendID, let friendName):
            CompareBirdsView(friendID: friendID, friendName: friendName)
        case .blockedAccounts:
            BlockedAccountsView()
        }
    }
}

extension EnvironmentValues {
    /// Opens the Collection tab at the top of the Patches view: the new-patch reveal's "See it in my collection" (issues #51, #132).
    @Entry var openCollection: @MainActor () -> Void = {}
    /// Opens the Listen tab: a species with no sightings yet (issue #53).
    @Entry var openListen: @MainActor () -> Void = {}
    /// Opens a circle's page on the Guilds tab: the join screen once joined (issue #61).
    @Entry var openCircle: @MainActor (String) -> Void = { _ in }
}

/// The destinations (issue #28): Listen, Collection (the journal, issue #117) and Atlas (the field guide), and Guilds
/// (circles, issue #61) in builds with accounts, with the compact listening strip above the tab bar while a run is on and
/// another tab is showing. The `Tab` cases keep their internal names.
struct RootView: View {
    enum Tab: String, Hashable {
        case listen, journal, guide, circles
    }

    @Environment(ListeningCoordinator.self) private var run
    @Environment(PackLibrary.self) private var library
    @Environment(CircleStore.self) private var circles
    @Environment(AccountSession.self) private var account
    @Environment(FindOutbox.self) private var findOutbox
    @Environment(PushCenter.self) private var pushes
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: Tab = .listen
    @State private var collection = CollectionState()
    @State private var listenPath = NavigationPath()
    @State private var journalPath = NavigationPath()
    @State private var guidePath = NavigationPath()
    @State private var circlesPath = NavigationPath()
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
            SwiftUI.Tab("Collection", systemImage: "leaf", value: Tab.journal) {
                NavigationStack(path: $journalPath) {
                    JournalView(state: collection, isCovered: tab != .journal || !journalPath.isEmpty)
                        .appDestinations()
                }
            }
            SwiftUI.Tab("Atlas", systemImage: "map", value: Tab.guide) {
                NavigationStack(path: $guidePath) {
                    FieldGuideView()
                        .appDestinations()
                }
            }
            // Circles need an account; #88's switch keeps both out of release builds until in-app deletion ships. When #71
            // turns it on in Release, give Release `CODE_SIGN_ENTITLEMENTS = BirdJournal.entitlements` too: the invite
            // links' associated domain is Debug-only until then, so a release build leaves them to the browser.
            if AccountSession.isEnabledInThisBuild {
                SwiftUI.Tab("Guilds", systemImage: "person.3", value: Tab.circles) {
                    NavigationStack(path: $circlesPath) {
                        CirclesView()
                            .appDestinations()
                    }
                }
            }
        }
        .tabViewBottomAccessory(isEnabled: run.state.isActive && tab != .listen) {
            ListeningAccessory { tab = .listen }
        }
        .tint(Color.moss)
        // Over the tabs and their bars. The run review sheet carries its own, since an add there happens over it, and while
        // it's up this one waits: two pages would sew the patch twice, each with its own haptics.
        .patchReveal(isCovered: run.isReviewing)
        .environment(\.openCollection) {
            collection.mode = .cards
            collection.query = ""
            collection.offsets[.cards] = 0
            journalPath = NavigationPath()
            tab = .journal
        }
        .environment(\.openListen) { tab = .listen }
        .environment(\.openCircle) { circleID in
            tab = .circles
            circlesPath = NavigationPath()
            circlesPath.append(Route.circle(id: circleID))
        }
        // Signed out (from Settings or a revoked token): nothing of the circles stays on the phone.
        .onChange(of: account.isSignedIn) { _, signedIn in
            if !signedIn {
                circles.clear()
                circlesPath = NavigationPath()
            } else {
                // Finds waiting from before a sign-out go now (issue #62).
                Task { await findOutbox.flush() }
            }
            // The phone's push token follows the account (issue #63).
            Task { await pushes.accountChanged() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await findOutbox.flush() }
                // Settings may have turned notifications on or off meanwhile.
                Task { await pushes.refreshPermission() }
            }
        }
        // A tapped push (issue #63): its circle, or the list for a digest.
        .onChange(of: pushes.pendingCircle) { _, circleID in
            guard let circleID, AccountSession.isEnabledInThisBuild else { return }
            pushes.pendingCircle = nil
            tab = .circles
            circlesPath = NavigationPath()
            if !circleID.isEmpty { circlesPath.append(Route.circle(id: circleID)) }
        }
        // The first circle created or joined (issue #63): why pushes, before the system asks.
        .alert("Hear about your friends' finds", isPresented: Bindable(pushes).isExplaining) {
            Button("Turn on notifications") { Task { await pushes.turnOn() } }
            Button("Not now", role: .cancel) { pushes.notNow() }
        } message: {
            Text(PushCenter.explanation)
        }
        // An invite link (issue #61), from a cold start or while running: the join screen on the Circles tab.
        .onChange(of: circles.pendingInvite, initial: true) { _, token in
            guard let token, AccountSession.isEnabledInThisBuild else { return }
            circles.pendingInvite = nil
            tab = .circles
            circlesPath = NavigationPath()
            circlesPath.append(Route.joinCircle(token: token))
        }
        // The index carries every pack's set (issue #54), so it is fetched at launch, not only on the packs screen;
        // the last good copy stands in meanwhile and offline.
        .task { await library.refreshIndex() }
        .task { await pushes.refreshPermission() }
        #if DEBUG
        .sheet(isPresented: $showingDeveloper) { DeveloperView() }
        .modifier(DebugLaunch(tab: $tab, journalMode: $collection.mode, listenPath: $listenPath, journalPath: $journalPath, guidePath: $guidePath, circlesPath: $circlesPath, showingDeveloper: $showingDeveloper))
        #endif
    }
}

