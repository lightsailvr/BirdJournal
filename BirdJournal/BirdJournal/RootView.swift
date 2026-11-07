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
    /// One patch, on its page with its paper card behind it (issue #134). `from` is the kind of tile it grows out of (issue #150);
    /// `turned` opens it on the paper card.
    case patch(CardCollection.Patch.Key, from: PatchLiftSurface? = nil, turned: Bool = false)
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
        case .patch(let key, let surface, let turned):
            PatchDetailView(key: key, startsTurned: turned)
                .patchLiftTransition(from: surface.map { PatchLiftID(key: key, surface: $0) })
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
            LicenseTextView(title: "Field guide license") {
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
    /// Opens the Collection tab at the top of the Patches view, on one board: the new patch on the reveal (issues #51, #132, #150).
    @Entry var openCollection: @MainActor (BoardChoice?) -> Void = { _ in }
    /// Opens the Listen tab: a species with no sightings yet (issue #53).
    @Entry var openListen: @MainActor () -> Void = {}
    /// Opens the Atlas tab: an empty collection's birds to find (issue #138).
    @Entry var openAtlas: @MainActor () -> Void = {}
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
    @Environment(CurrentPlace.self) private var place
    @Environment(PushCenter.self) private var pushes
    @Environment(CollectionStore.self) private var collectionStore
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
    /// The launch splash is still over this: a ceremony waits for it, rather than starting unseen.
    var isUnderSplash = false
    /// A patch the widget opened (issue #150), cleared once shown.
    @Binding var pendingPatch: CardCollection.Patch.Key?
    /// No sheet is up for a run's review to take the place of.
    @State private var isClearForReview = false

    /// A sheet, alert or the like is up. There are many, in many views, and no one place that knows of them all but UIKit.
    private static var isSomethingPresented: Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .contains { $0.rootViewController?.presentedViewController != nil }
    }

    /// The patch's page on the Collection tab, or the tab alone if the patch has been unpicked since the widget last drew. An
    /// open run review goes first: its skipped birds are forgotten when it closes, so it isn't closed for them.
    private func openPendingPatch() {
        guard let key = pendingPatch, !run.isReviewing else { return }
        pendingPatch = nil
        collection.mode = .cards
        journalPath = NavigationPath()
        tab = .journal
        if collectionStore.collection.patch(key: key) != nil { journalPath.append(Route.patch(key)) }
    }

    var body: some View {
        TabView(selection: $tab) {
            SwiftUI.Tab("Listen", systemImage: "waveform", value: Tab.listen) {
                NavigationStack(path: $listenPath) {
                    ListenView()
                        .appDestinations()
                }
                .patchStack { listenPath.append($0) }
            }
            SwiftUI.Tab("Collection", image: "stitched.ring", value: Tab.journal) {
                NavigationStack(path: $journalPath) {
                    JournalView(state: collection, isCovered: tab != .journal || !journalPath.isEmpty)
                        .appDestinations()
                }
                .patchStack { journalPath.append($0) }
            }
            SwiftUI.Tab("Atlas", systemImage: "map", value: Tab.guide) {
                NavigationStack(path: $guidePath) {
                    FieldGuideView()
                        .appDestinations()
                }
                .patchStack { guidePath.append($0) }
            }
            // Circles need an account; #88's switch keeps both out of release builds until in-app deletion ships. When #71
            // turns it on in Release, add what's in `BirdJournal.entitlements` to `BirdJournal-Release.entitlements`: the invite
            // links' associated domain is Debug-only until then, so a release build leaves them to the browser.
            if AccountSession.isEnabledInThisBuild {
                SwiftUI.Tab("Guilds", systemImage: "person.3", value: Tab.circles) {
                    NavigationStack(path: $circlesPath) {
                        CirclesView()
                            .appDestinations()
                    }
                    .patchStack { circlesPath.append($0) }
                }
            }
        }
        .tabViewBottomAccessory(isEnabled: run.state.isActive && tab != .listen) {
            ListeningAccessory { tab = .listen }
        }
        // Here, so Start and both Stops say the same, and a run the glasses end does too.
        // A run that failed says that, and only that.
        .haptic(.startStop, trigger: run.isRunGoing) { _, _ in !run.hasFailed }
        .haptic(.error, trigger: run.hasFailed) { _, failed in failed }
        .haptic(.error, trigger: run.failedActions)
        // The end of a run, from whichever tab it finds the birder on (issue #150). On the Listen tab's own view it could only be
        // presented with that tab showing: on another, SwiftUI gave up on it and the birds heard went with it. It waits for any
        // sheet already up to close, since only one can be: over a bird's review or New Guild it would throw away what's in it.
        .sheet(isPresented: Binding(get: { run.isReviewing && isClearForReview }, set: { if !$0 { run.isReviewing = false } })) {
            RunReviewSheet()
        }
        .task(id: run.isReviewing) {
            isClearForReview = false
            guard run.isReviewing else { return }
            while !Task.isCancelled, Self.isSomethingPresented { try? await Task.sleep(for: .milliseconds(300)) }
            if !Task.isCancelled { isClearForReview = true }
        }
        // Over the tabs and their bars. The run review sheet carries its own, since an add there happens over it, and while
        // it's up this one waits: two pages would sew the patch twice, each with its own haptics.
        .patchReveal(isCovered: run.isReviewing)
        // The accent follows the place (issue #150), over the reveal too; a set's page and a patch's page set their own.
        .tint(place.setID.map(PatchEdition.tint(setID:)) ?? .moss)
        // The patches a glasses run sewed: once it's over and the app is in front, which may be a launch or two later.
        .onChange(of: scenePhase == .active && !isUnderSplash && run.hasCeremonyWaiting, initial: true) { _, ready in
            if ready { run.showNextCeremony() }
        }
        .environment(\.openCollection) { board in
            collection.mode = .cards
            collection.query = ""
            collection.offsets[.cards] = 0
            collection.board = board
            journalPath = NavigationPath()
            tab = .journal
        }
        .environment(\.openListen) { tab = .listen }
        .environment(\.openAtlas) { tab = .guide }
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
        .onChange(of: pendingPatch, initial: true) { openPendingPatch() }
        .onChange(of: run.isReviewing) { openPendingPatch() }
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
        .overlay(alignment: .topLeading) { HapticLogProbe() }
        .modifier(DebugLaunch(tab: $tab, journalMode: $collection.mode, listenPath: $listenPath, journalPath: $journalPath, guidePath: $guidePath, circlesPath: $circlesPath, showingDeveloper: $showingDeveloper))
        #endif
    }
}

