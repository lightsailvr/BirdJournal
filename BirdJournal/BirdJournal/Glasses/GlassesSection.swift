import MWDATCore
import SwiftUI

/// Registration and linked glasses on the phone screen, with the update flows the toolkit asks for.
struct GlassesSection: View {
    @Environment(GlassesConnection.self) private var connection

    var body: some View {
        Section("Glasses") {
            LabeledContent("Meta AI", value: connection.registrationText)
            switch connection.registrationState {
            case .registered:
                Button("Unregister", role: .destructive) { Task { await connection.unregister() } }
            case .available:
                Button("Register with Meta AI") { Task { await connection.register() } }
            case .registering, .unavailable:
                EmptyView()
            @unknown default:
                EmptyView()
            }

            if connection.devices.isEmpty {
                Text("No glasses linked in Meta AI").foregroundStyle(.secondary)
            }
            ForEach(connection.devices) { device in
                GlassesDeviceRow(device: device)
            }

            if connection.glassesAppUpdateRequired {
                Button("Update the glasses app") { Task { await connection.openGlassesAppUpdate() } }
            }
            if let errorMessage = connection.errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
        }

        #if DEBUG
        Section("Mock Device Kit") {
            if connection.isMockPaired {
                Button("Take off mock glasses") { connection.setMockWorn(false) }
                Button("Put on mock glasses") { connection.setMockWorn(true) }
                Button("Unpair mock glasses", role: .destructive) { Task { await connection.unpairMockGlasses() } }
            } else {
                Button("Pair mock Meta Ray-Ban Display") { connection.pairMockGlasses() }
            }
        }
        #endif
    }
}
