import LensSession
import MWDATCore
import MWDATInputs
import SwiftUI

/// Phase A lens screen: start the card on the lens, watch every Nav and Select arrive, and drive the mock lens
/// from the phone when no glasses are on.
struct LensSessionView: View {
    @Environment(GlassesConnection.self) private var connection
    @Environment(GlassesLensSession.self) private var lens

    var body: some View {
        List {
            Section {
                LabeledContent("Run", value: phaseText)
                LabeledContent("Session", value: lens.sessionState.description)
                LabeledContent("Display", value: String(describing: lens.displayState))
                LabeledContent("Inputs", value: lens.inputsState.description)

                if lens.phase == .starting {
                    HStack {
                        ProgressView()
                        Text("Starting…")
                    }
                } else if lens.isActive {
                    Button("Stop", role: .destructive) { Task { await lens.stop() } }
                } else {
                    Button("Start") { Task { await lens.start() } }
                }

                if let errorMessage = lens.errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
                if connection.glassesAppUpdateRequired {
                    Button("Update the glasses app") { Task { await connection.openGlassesAppUpdate() } }
                }
            } footer: {
                Text("Swipe and tap with the Neural Band once the card shows. The two-finger tap ends the session from the glasses.")
            }

            #if DEBUG
            MockLensSection()
            #endif

            Section("Card on the lens") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(lens.card.heading).font(.headline)
                    Text(lens.card.body)
                    Text(lens.card.buttonLabel)
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.tint.opacity(0.2), in: Capsule())
                }
                LabeledContent("Button clicks", value: "\(lens.buttonClicks)")
            }

            Section("Inputs from the glasses") {
                if lens.inputRecords.isEmpty {
                    Text("Nothing received yet").foregroundStyle(.secondary)
                }
                ForEach(lens.inputRecords) { record in
                    HStack {
                        Text(record.receivedAt, format: .dateTime.hour().minute().second().secondFraction(.fractional(1)))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text(record.gesture?.name ?? record.description)
                        Spacer()
                        if record.gesture != nil {
                            Text(record.description).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Lens card")
    }

    private var phaseText: String {
        switch lens.phase {
        case .idle: "Not started"
        case .starting: "Starting"
        case .running: "On the lens"
        case .stopping: "Stopping"
        case .stopped(.phone): "Stopped from the phone"
        case .stopped(.glasses): "Ended by the glasses"
        case .stopped(.failed): "Failed"
        }
    }
}

#if DEBUG
/// The mock lens rendered on the phone, with buttons that stand in for the Neural Band.
private struct MockLensSection: View {
    @Environment(GlassesConnection.self) private var connection
    @Environment(GlassesLensSession.self) private var lens
    @State private var preview: UIView?

    var body: some View {
        Section("Mock lens") {
            if connection.isMockPaired {
                if let preview {
                    MockDisplayPreview(view: preview)
                        .frame(width: 300, height: 300)
                        .frame(maxWidth: .infinity)
                        .listRowInsets(EdgeInsets())
                        .background(.black)
                }
                HStack {
                    ForEach(GlassesConnection.MockInput.allCases) { input in
                        Button(input.title) { connection.injectMockInput(input) }
                            .buttonStyle(.bordered)
                    }
                }
                .disabled(!lens.isActive)
                .font(.caption)
            } else {
                Button("Pair mock Meta Ray-Ban Display") { connection.pairMockGlasses() }
            }
        }
        .task(id: connection.isMockPaired) {
            preview = connection.isMockPaired ? connection.makeMockDisplayPreview() : nil
        }
    }
}

private struct MockDisplayPreview: UIViewRepresentable {
    let view: UIView

    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif
