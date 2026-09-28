import MWDATCore
import SwiftUI

/// The choice of audio source (issue #28): the glasses or the iPhone microphone, with registration, connection and
/// update needs in plain words, and what each source asks for and why.
struct AudioSourceSheet: View {
    @Environment(ListeningCoordinator.self) private var run
    @Environment(GlassesConnection.self) private var connection
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var run = run
        NavigationStack {
            List {
                Section {
                    ForEach(ListeningCoordinator.Source.allCases) { source in
                        Button {
                            run.source = source
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: source.symbol)
                                    .frame(width: 28)
                                    .foregroundStyle(Color.ink)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(source.title).foregroundStyle(Color.ink)
                                    Text(detail(for: source))
                                        .font(JournalFont.supporting)
                                        .foregroundStyle(Color.inkSecondary)
                                }
                                Spacer()
                                if run.source == source {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(Color.moss)
                                }
                            }
                        }
                        .accessibilityAddTraits(run.source == source ? .isSelected : [])
                    }
                } header: {
                    Text("Listen with")
                } footer: {
                    Text("Birds are identified from sound on this iPhone by BirdNET. No audio is saved or sent anywhere.")
                }

                Section("Ray-Ban Display") {
                    LabeledContent("Meta AI", value: connection.registrationText)
                    if connection.registrationState == .available {
                        Button("Register with Meta AI") { Task { await connection.register() } }
                    } else if connection.registrationState == .registered {
                        Button("Unregister", role: .destructive) { Task { await connection.unregister() } }
                    }
                    if connection.devices.isEmpty {
                        Text("No glasses are linked in the Meta AI app.")
                            .foregroundStyle(Color.inkSecondary)
                    }
                    ForEach(connection.devices) { device in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(device.name)
                            Text(linkText(device))
                                .font(JournalFont.supporting)
                                .foregroundStyle(Color.inkSecondary)
                            if device.state.compatibility == .deviceUpdateRequired {
                                Button("Update glasses firmware") { Task { await connection.openFirmwareUpdate() } }
                            }
                        }
                    }
                    if connection.glassesAppUpdateRequired {
                        Button("Update the glasses app") { Task { await connection.openGlassesAppUpdate() } }
                    }
                    if let error = connection.errorMessage {
                        Text(error).foregroundStyle(.red).font(JournalFont.supporting)
                    }
                }

                Section("What each source asks for") {
                    Text("The iPhone microphone asks for microphone access the first time you start listening. Sound is analysed on the phone as it arrives and never saved.")
                        .font(JournalFont.supporting)
                        .foregroundStyle(Color.inkSecondary)
                    Text("The glasses' microphones only reach the phone inside their camera stream, so BirdJournal asks Meta AI for camera and microphone access the first time. The video is not used to tell birds apart; the most recent frame is kept with a sighting you add, as a snapshot of where you were looking.")
                        .font(JournalFont.supporting)
                        .foregroundStyle(Color.inkSecondary)
                    Text("Location narrows the list to birds that live where you are. Without it every species stays possible, which means more lookalikes to review.")
                        .font(JournalFont.supporting)
                        .foregroundStyle(Color.inkSecondary)
                }
            }
            .paperList()
            .navigationTitle("Audio source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }

    private func detail(for source: ListeningCoordinator.Source) -> String {
        switch source {
        case .phone: "Works anywhere. Keep the phone out where it can hear."
        case .glasses: connection.connectedDevice != nil ? "Connected. Lock the phone and look up." : "Uses the glasses camera stream for sound."
        }
    }

    private func linkText(_ device: GlassesDeviceStatus) -> String {
        var parts = [device.linkText]
        if let battery = device.state.batteryLevel { parts.append("battery \(battery)%") }
        if device.state.compatibility != .compatible { parts.append(device.state.compatibility.displayString) }
        return parts.joined(separator: " · ")
    }
}
