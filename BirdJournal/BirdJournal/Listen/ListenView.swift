import Album
import Identification
import MWDATCore
import Pack
import SwiftData
import SwiftUI

/// The Listen tab (issue #28): one Start listening action over the chosen audio source when idle, and the live run
/// (source, elapsed time, waveform, species heard, Stop) once it is under way. Runs live in the
/// `ListeningCoordinator`, so leaving the tab never ends one.
struct ListenView: View {
    @Environment(ListeningCoordinator.self) private var run
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var run = run
        Group {
            if run.state.isActive || (run.state != .idle && !run.candidates.isEmpty) {
                ActiveListeningView()
            } else {
                ReadyToListenView()
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
        .sheet(isPresented: $run.isReviewing) {
            RunReviewSheet()
        }
        .safeAreaInset(edge: .bottom) {
            if let acknowledgment = run.acknowledgment {
                Toast(text: acknowledgment.text, undo: acknowledgment.undo.map { addition in { run.undo(addition) } })
                    .padding(.bottom, 8)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .default, value: run.acknowledgment)
    }
}

/// The quiet page: a source row, Start listening, and the last thing in the journal.
private struct ReadyToListenView: View {
    @Environment(ListeningCoordinator.self) private var run
    @Environment(GlassesConnection.self) private var connection
    @Query(Sighting.newestFirst()) private var sightings: [Sighting]
    @State private var choosingSource = false

    var body: some View {
        PaperPage {
            VStack(alignment: .leading, spacing: 0) {
                Text("Make room for a little birdsong.")
                    .font(JournalFont.body)
                    .foregroundStyle(Color.inkSecondary)
                    .padding(.top, 2)

                PerchedBirdDrawing()
                    .frame(height: 118)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                    .accessibilityHidden(true)

                AudioSourceRow(source: run.source, status: sourceStatus) { choosingSource = true }
                Text(run.source.microphoneText)
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.inkSecondary)
                    .padding(.top, 8)

                if case .ended(.failed(let message)) = run.state {
                    ErrorNotice("Listening stopped", message: message) {
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
                }
                .buttonStyle(.journalPrimary)
                .disabled(run.state == .starting)
                .padding(.top, 20)
                .accessibilityHint(run.source == .glasses ? "Starts listening with the glasses microphones" : "Starts listening with the iPhone microphone")

                Text(run.source == .glasses ? "You can lock your phone and look up." : "Keep your phone out where it can hear.")
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.inkSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)

                if let latest = sightings.first {
                    SectionTitle(text: "Last in your journal")
                    NavigationLink(value: Route.sighting(latest.persistentModelID)) {
                        LatestSightingCard(sighting: latest)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 14)
                } else {
                    SectionTitle(text: "Your journal")
                    Text("Birds you add while listening are kept here, one sighting at a time, with the day, the place and a note if you like.")
                        .font(JournalFont.body)
                        .foregroundStyle(Color.inkSecondary)
                        .padding(.top, 12)
                }
            }
        }
        .navigationTitle("Listen")
        .sheet(isPresented: $choosingSource) {
            AudioSourceSheet()
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

    private var sourceStatus: String {
        switch run.source {
        case .phone: "Ready"
        case .glasses:
            if connection.registrationState != .registered { "Not registered" }
            else if let device = connection.connectedDevice { device.state.compatibility == .compatible ? "Connected" : "Update needed" }
            else if connection.devices.isEmpty { "No glasses linked" }
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
        switch connection.registrationState {
        case .registered: break
        case .available:
            return Blocker(title: "Register with Meta AI", message: "The Meta AI app has to allow BirdJournal on your glasses once. Registration opens Meta AI and comes back here.", action: AnyView(Button("Register") { Task { await connection.register() } }))
        case .registering:
            return Blocker(title: "Registering with Meta AI…", message: "Finish the steps in the Meta AI app.", action: AnyView(EmptyView()))
        case .unavailable:
            return Blocker(title: "Meta AI is not available", message: "Install the Meta AI app and pair your Ray-Ban Display in it, or listen with the iPhone microphone.", action: AnyView(Button("Use iPhone microphone") { run.source = .phone }))
        @unknown default:
            break
        }
        if connection.glassesAppUpdateRequired {
            return Blocker(title: "Update the glasses app", message: "The Meta app on the glasses is too old for this BirdJournal build.", action: AnyView(Button("Update") { Task { await connection.openGlassesAppUpdate() } }))
        }
        if connection.devices.isEmpty {
            return Blocker(title: "No glasses linked", message: "Pair your Ray-Ban Display in the Meta AI app, or listen with the iPhone microphone for now.", action: AnyView(Button("Use iPhone microphone") { run.source = .phone }))
        }
        guard let device = connection.connectedDevice else {
            return Blocker(title: "Glasses not connected", message: "Turn the glasses on and keep them near your iPhone with Bluetooth on. Listening starts once they connect.", action: AnyView(Button("Use iPhone microphone") { run.source = .phone }))
        }
        switch device.state.compatibility {
        case .deviceUpdateRequired:
            return Blocker(title: "Update the glasses", message: "The glasses firmware is too old for this BirdJournal build.", action: AnyView(Button("Update firmware") { Task { await connection.openFirmwareUpdate() } }))
        case .sdkUpdateRequired:
            return Blocker(title: "BirdJournal needs an update", message: "This build's toolkit is older than the glasses require. Update the app.", action: AnyView(EmptyView()))
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
                    Text(status)
                        .font(JournalFont.supporting)
                        .foregroundStyle(Color.inkSecondary)
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
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(source.title), \(status)")
        .accessibilityHint(isEnabled ? "Choose the audio source" : "")
    }
}

/// The newest sighting as a wide card: the glasses snapshot when there is one, else the reference photo, labelled.
private struct LatestSightingCard: View {
    @Environment(PackLibrary.self) private var library
    @Environment(PlaceNames.self) private var places
    let sighting: Sighting

    var body: some View {
        let reference = library.species(scientificName: sighting.scientificName)
        Color.clear
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay {
                if sighting.frameImagePath != nil {
                    FrameImage(frameImagePath: sighting.frameImagePath)
                } else if let reference, let photo = reference.species.photos.first {
                    PackImage(url: reference.pack.phoneImageURL(for: photo))
                } else {
                    Color.raised
                }
            }
            .overlay(alignment: .bottomLeading) {
            LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 3) {
                Text(library.commonName(for: sighting))
                    .font(JournalFont.heading)
                    .foregroundStyle(.white)
                Text("\(Journal.title(for: sighting.confirmedAt)) · \(places.placeText(for: sighting.location))")
                    .font(JournalFont.supporting)
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                Text(sighting.frameImagePath != nil ? "Your glasses snapshot" : (reference?.species.photos.first.map { "Reference photo · \($0.shortCredit)" } ?? "No photo"))
                    .font(JournalFont.attribution)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            .padding(16)
        }
        .clipShape(RoundedRectangle(cornerRadius: JournalLayout.cornerRadius, style: .continuous))
        .task(id: sighting.location) {
            if let location = sighting.location { await places.resolve(location) }
        }
        .accessibilityElement(children: .combine)
    }
}
