import Album
import Identification
import MWDATCore
import Pack
import SwiftUI

/// The Listen tab (issue #28; issue #117's ready and active states): one Start listening action over the chosen audio
/// source under the local set's cover when idle, and the live run (source, elapsed time, waveform, species heard,
/// Stop) without decoration once it is under way. Runs live in the
/// `ListeningCoordinator`, so leaving the tab never ends one.
struct ListenView: View {
    @Environment(ListeningCoordinator.self) private var run
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { PatchMotion.reduces(system: systemReduceMotion) }
    @Environment(\.warmEngine) private var warmEngine
    /// Whether another page covers this one: a page pushed on the tab's stack, or another tab.
    var isCovered = false

    var body: some View {
        @Bindable var run = run
        Group {
            if run.state.isActive || (run.state != .idle && !(run.candidates.isEmpty && run.sightings.seen.isEmpty)) {
                ActiveListeningView()
            } else {
                ReadyToListenView(isCovered: isCovered)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: Route.settings) {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .sheet(item: $run.reviewing) { candidate in
            CandidateReviewSheet(candidate: candidate)
        }
        // The camera and the naming of its photo (issue #186), over the tab bar too: a camera has the whole screen.
        .fullScreenCover(isPresented: $run.isCapturing) {
            CaptureSightingView()
        }
        .safeAreaInset(edge: .bottom) {
            // Over the review, the sheet has its own: two would each tick, with two haptics.
            if let acknowledgment = run.acknowledgment, !run.isReviewing {
                Toast(text: acknowledgment.text, undo: acknowledgment.undo.map { addition in { run.undo(addition) } }, ticksFrom: acknowledgment.ticksFrom)
                    .id(acknowledgment.id)
                    .padding(.bottom, 8)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .default, value: run.acknowledgment)
        // After the first frame, so Start is ready before it's tapped (issue #150). Not during a run: it holds its own engine,
        // and if a memory warning has dropped the shared one, this would load a second beside it.
        .task {
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled, !run.state.isActive { warmEngine() }
        }
    }
}

extension EnvironmentValues {
    /// Loads the identification engine ahead of a run. The app's root sets it; elsewhere nothing happens.
    @Entry var warmEngine: () -> Void = {}
}

/// The calm ready state (issue #117, design guide page 11): the local set's cover as the atmosphere, the connection
/// with the chosen microphones, one obvious Start listening, and the local set with the birder's progress in it. The
/// navigation bar gives way to the cover; Settings sits on it.
private struct ReadyToListenView: View {
    @Environment(ListeningCoordinator.self) private var run
    @Environment(GlassesConnection.self) private var connection
    @Environment(PackLibrary.self) private var library
    @Environment(CollectionStore.self) private var collectionStore
    @Environment(CurrentPlace.self) private var place
    @Environment(CircleStore.self) private var circles
    @Environment(\.scenePhase) private var scenePhase
    var isCovered = false
    @State private var choosingSource = false

    /// What a new read of the place answers to: Listen appearing (a task always starts then), coming back to the front, a set
    /// the phone has just learned, or a sighting that moves the fallback.
    private struct PlaceRead: Equatable {
        let sets: [String]
        let newest: String?
        let inFront: Bool
    }

    /// The status bar's height, which the cover runs under: the window's inset, since this page's own safe area also counts the
    /// navigation bar, and the cover's words stay where they were without one.
    private static var statusBarInset: CGFloat? {
        UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first?.keyWindow?.safeAreaInsets.top
    }

    var body: some View {
        let collection = collectionStore.collection
        let local = LocalSet(setID: place.setID, library: library, collection: collection)
        GeometryReader { proxy in
            ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // The cover's words sit under the status bar, level with the gear on the navigation bar.
                    ListenCoverHeader(local: local, topInset: Self.statusBarInset ?? proxy.safeAreaInsets.top)
                    VStack(alignment: .leading, spacing: 0) {
                        AudioSourceRow(source: run.source, status: sourceStatus, isConnected: isConnected) { choosingSource = true }

                        if case .ended(.failed(let message)) = run.state {
                            ErrorNotice(Self.failureTitle(message), message: message, symbol: Self.failureSymbol(message)) {
                                RecoveryActions(message: message)
                            }
                            .padding(.top, 16)
                        } else if case .ended(.endedByGlasses) = run.state {
                            ErrorNotice("Listening stopped", message: "The glasses ended the session. Start again when you are ready.", symbol: "eyeglasses")
                                .padding(.top, 16)
                        }
                        if run.source == .glasses, let blocker = glassesBlocker {
                            ErrorNotice(blocker.title, message: blocker.message, symbol: "eyeglasses") {
                                blocker.action
                            }
                            .padding(.top, 16)
                        }

                        Button {
                            Task { await run.start() }
                        } label: {
                            Label("Start listening", systemImage: "waveform")
                                .font(.title3.weight(.semibold))
                        }
                        .buttonStyle(.journalPrimary)
                        .disabled(run.state == .starting)
                        .padding(.top, 20)
                        .accessibilityHint(run.source == .glasses ? "Starts listening with the glasses microphones" : "Starts listening with the iPhone microphone")

                        if let local {
                            LocalSetSection(local: local, collection: collection)
                                .id("local-set")
                        }
                        GuildGoalLine()
                            .padding(.top, 18)
                    }
                    .padding(.horizontal, JournalLayout.margin)
                    .padding(.top, -36)
                    .padding(.bottom, JournalLayout.sectionGap)
                }
            }
            .keepsItsFootUnderAPage(isCovered: isCovered)
            .ignoresSafeArea(edges: .top)
            .background(Color.paper)
            #if DEBUG
            .debugScroll(scroll, to: "local-set")
            #endif
            }
        }
        .navigationTitle("Listen")
        // The bar stays for the gear, on real glass over the painting (issue #150); the painting carries the screen's words.
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .sheet(isPresented: $choosingSource) {
            AudioSourceSheet()
        }
        .task(id: PlaceRead(sets: collection.sets.map(\.id), newest: LocalSet.newestSetID(in: collection), inFront: scenePhase != .background)) {
            if scenePhase != .background { await place.refresh() }
        }
        // After the first frame, like the engine.
        .task {
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { await circles.loadRunningGoals() }
        }
        #if DEBUG
        .task {
            if UserDefaults.standard.bool(forKey: "autoSource") {
                UserDefaults.standard.removeObject(forKey: "autoSource")
                try? await Task.sleep(for: .milliseconds(600))
                choosingSource = true
            }
        }
        #endif
    }

    /// A denied permission says what is off (issue #119); anything else is that listening stopped.
    static func failureTitle(_ message: String) -> String {
        if message.localizedCaseInsensitiveContains("Microphone access") { return "Microphone access is off" }
        if message.localizedCaseInsensitiveContains("permission was not granted") { return "Glasses access is off" }
        return "Listening stopped"
    }

    static func failureSymbol(_ message: String) -> String {
        if message.localizedCaseInsensitiveContains("Microphone access") { return "mic.slash" }
        if message.localizedCaseInsensitiveContains("permission was not granted") { return "eyeglasses" }
        return "exclamationmark.triangle"
    }

    /// The glasses as the toolkit reports them; in debug builds `-fakeGlasses unregistered|noneLinked|notConnected`
    /// stands in for them (issue #119's screenshots of the disconnected states, which the simulator can't reach).
    private var registrationState: RegistrationState {
        #if DEBUG
        if let fake = FakeGlasses.current { return fake.registrationState }
        #endif
        return connection.registrationState
    }

    private var devices: [GlassesDeviceStatus] {
        #if DEBUG
        if let fake = FakeGlasses.current { return fake.devices }
        #endif
        return connection.devices
    }

    private var connectedDevice: GlassesDeviceStatus? {
        devices.first { $0.state.linkState == .connected }
    }

    /// Whether the chosen source can listen now: the dot on the source row.
    private var isConnected: Bool {
        switch run.source {
        case .phone: true
        case .glasses: registrationState == .registered && connectedDevice?.state.compatibility == .compatible
        }
    }

    private var sourceStatus: String {
        switch run.source {
        case .phone: "Ready"
        case .glasses:
            if registrationState != .registered { "Not registered" }
            else if let device = connectedDevice { device.state.compatibility == .compatible ? "Connected" : "Update needed" }
            else if devices.isEmpty { "No glasses linked" }
            else { "Not connected" }
        }
    }

    private struct Blocker {
        let title: String
        let message: String
        let action: AnyView
    }

    /// Why a glasses run could not start right now, with the way to fix it; nil when it can.
    private var glassesBlocker: Blocker? {
        switch registrationState {
        case .registered: break
        case .available:
            return Blocker(title: "Register with Meta AI", message: "The Meta AI app has to allow Featherguild on your glasses once. Registration opens Meta AI and comes back here.", action: AnyView(Button("Register") { Task { await connection.register() } }))
        case .registering:
            return Blocker(title: "Registering with Meta AI…", message: "Finish the steps in the Meta AI app.", action: AnyView(EmptyView()))
        case .unavailable:
            return Blocker(title: "Meta AI is not available", message: "Install the Meta AI app and pair your Ray-Ban Display in it, or listen with the iPhone microphone.", action: AnyView(Button("Use iPhone microphone") { run.source = .phone }))
        @unknown default:
            break
        }
        if connection.glassesAppUpdateRequired {
            return Blocker(title: "Update the glasses app", message: "The Meta app on the glasses is too old for this Featherguild build.", action: AnyView(Button("Update") { Task { await connection.openGlassesAppUpdate() } }))
        }
        if devices.isEmpty {
            return Blocker(title: "No glasses linked", message: "Pair your Ray-Ban Display in the Meta AI app, or listen with the iPhone microphone for now.", action: AnyView(Button("Use iPhone microphone") { run.source = .phone }))
        }
        guard let device = connectedDevice else {
            return Blocker(title: "Glasses not connected", message: "Turn the glasses on and keep them near your iPhone with Bluetooth on. Listening starts once they connect.", action: AnyView(Button("Use iPhone microphone") { run.source = .phone }))
        }
        switch device.state.compatibility {
        case .deviceUpdateRequired:
            return Blocker(title: "Update the glasses", message: "The glasses firmware is too old for this Featherguild build.", action: AnyView(Button("Update firmware") { Task { await connection.openFirmwareUpdate() } }))
        case .sdkUpdateRequired:
            return Blocker(title: "Featherguild needs an update", message: "This build's toolkit is older than the glasses require. Update the app.", action: AnyView(EmptyView()))
        default:
            return nil
        }
    }
}

/// The actions a failure message calls for: Settings when a permission is missing, nothing otherwise.
struct RecoveryActions: View {
    @Environment(\.openURL) private var openURL
    let message: String

    var body: some View {
        if message.localizedCaseInsensitiveContains("permission") || message.localizedCaseInsensitiveContains("not granted") || message.localizedCaseInsensitiveContains("Settings") {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
        }
    }
}

/// The compact source and status row: glasses or iPhone, connected or not, opening the choice.
struct AudioSourceRow: View {
    let source: ListeningCoordinator.Source
    let status: String
    /// A dot before the status: the tint for a source ready to listen, or a hollow ring.
    var isConnected: Bool?
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: source.symbol)
                    .font(.title3)
                    .foregroundStyle(Color.ink)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.title)
                        .font(JournalFont.rowTitle)
                        .foregroundStyle(Color.ink)
                    HStack(spacing: 6) {
                        if let isConnected {
                            Circle()
                                .fill(isConnected ? AnyShapeStyle(TintShapeStyle.tint) : AnyShapeStyle(Color.clear))
                                .overlay(Circle().strokeBorder(isConnected ? Color.clear : Color.inkSecondary, lineWidth: 1.5))
                                .frame(width: 8, height: 8)
                                .accessibilityHidden(true)
                        }
                        Text(status)
                            .font(JournalFont.supporting)
                            .foregroundStyle(Color.inkSecondary)
                    }
                }
                Spacer()
                if isEnabled {
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.inkSecondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: 60)
            .background(Color.raised, in: RoundedRectangle(cornerRadius: JournalLayout.cornerRadius, style: .continuous))
        }
        .buttonStyle(.journalPress)
        .disabled(!isEnabled)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(source.title), \(status)")
        .accessibilityHint(isEnabled ? "Choose the audio source" : "")
    }
}

#if DEBUG
/// `-fakeGlasses unregistered|noneLinked|notConnected` (issue #119): the Listen page's glasses states without glasses.
enum FakeGlasses: String {
    case unregistered, noneLinked, notConnected

    static var current: FakeGlasses? {
        UserDefaults.standard.string(forKey: "fakeGlasses").flatMap(FakeGlasses.init(rawValue:))
    }

    var registrationState: RegistrationState { self == .unregistered ? .available : .registered }

    var devices: [GlassesDeviceStatus] {
        guard self == .notConnected else { return [] }
        return [GlassesDeviceStatus(id: "fake-glasses", name: "Ray-Ban Display", type: .unknown, state: DeviceState(linkState: .disconnected))]
    }
}
#endif
