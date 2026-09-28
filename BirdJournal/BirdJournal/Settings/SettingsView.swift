import MWDATCore
import Pack
import SwiftUI

/// Settings (issue #28): the glasses in plain words, the bird packs, sources and credits, and, in debug builds, the
/// developer screens that used to be the app's front page.
struct SettingsView: View {
    @Environment(GlassesConnection.self) private var connection
    @Environment(PackLibrary.self) private var library
    @Environment(ListeningCoordinator.self) private var run

    var body: some View {
        @Bindable var run = run
        List {
            Section {
                Picker("Listen with", selection: $run.source) {
                    ForEach(ListeningCoordinator.Source.allCases) { Text($0.title).tag($0) }
                }
                .disabled(run.state.isActive)
                LabeledContent("Meta AI", value: registrationText)
                switch connection.registrationState {
                case .available:
                    Button("Register with Meta AI") { Task { await connection.register() } }
                case .registered:
                    Button("Unregister", role: .destructive) { Task { await connection.unregister() } }
                case .registering, .unavailable:
                    EmptyView()
                @unknown default:
                    EmptyView()
                }
                if connection.devices.isEmpty {
                    Text("No glasses linked in the Meta AI app.").foregroundStyle(Color.inkSecondary)
                }
                ForEach(connection.devices) { device in
                    GlassesDeviceRow(device: device)
                }
                if connection.glassesAppUpdateRequired {
                    Button("Update the glasses app") { Task { await connection.openGlassesAppUpdate() } }
                }
                if let error = connection.errorMessage {
                    Text(error).foregroundStyle(.red).font(JournalFont.supporting)
                }
            } header: {
                Text("Glasses")
            } footer: {
                Text("BirdJournal registers with the Meta AI app once, then listens through the glasses' camera stream, which carries their microphones. Camera frames are not used to identify birds; the latest one is kept as a snapshot when you add a bird.")
            }

            Section("Field guide") {
                NavigationLink(value: Route.packs) {
                    LabeledContent("Bird packs", value: library.packs.map(\.info.name).joined(separator: ", "))
                }
            }

            Section("About") {
                NavigationLink("Sources & credits", value: Route.credits)
                LabeledContent("Version", value: Self.versionText)
                Text("Powered by BirdNET. Birds are identified on this iPhone; no audio is saved or sent anywhere.")
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.inkSecondary)
            }

            #if DEBUG
            Section("Developer") {
                NavigationLink("Developer tools", value: Route.developer)
            }
            #endif
        }
        .paperList()
        .navigationTitle("Settings")
    }

    private var registrationText: String {
        switch connection.registrationState {
        case .unavailable: "Unavailable"
        case .available: "Not registered"
        case .registering: "Registering…"
        case .registered: "Registered"
        @unknown default: "Unknown"
        }
    }

    static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

/// One linked pair of glasses: link, compatibility, battery, and the update it may need.
struct GlassesDeviceRow: View {
    @Environment(GlassesConnection.self) private var connection
    let device: GlassesDeviceStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(device.name).font(.headline)
            Text("\(linkText) · \(device.state.compatibility.displayString)")
                .font(JournalFont.supporting)
                .foregroundStyle(device.state.linkState == .connected && device.state.compatibility == .compatible ? Color.moss : Color.inkSecondary)
            if let battery = device.state.batteryLevel {
                Text("Battery \(battery)%\(device.state.chargingState == .charging ? ", charging" : "")")
                    .font(JournalFont.attribution)
                    .foregroundStyle(Color.inkSecondary)
            }
            switch device.state.compatibility {
            case .deviceUpdateRequired:
                Button("Update glasses firmware") { Task { await connection.openFirmwareUpdate() } }
            case .sdkUpdateRequired:
                Text("This BirdJournal build needs a newer toolkit.").font(JournalFont.attribution).foregroundStyle(.red)
            default:
                EmptyView()
            }
        }
    }

    private var linkText: String {
        switch device.state.linkState {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .disconnected: "Not connected"
        }
    }
}
