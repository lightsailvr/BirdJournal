import Identification
import LensSession
import MWDATCore
import MWDATInputs
import SwiftUI

/// The lens screen: start the pages on the lens, follow the page the wearer is on, watch every Nav, Select and Back
/// arrive, and drive the mock lens from the phone when no glasses are on.
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
                Text("Swipe left and right between species, down for the description, up to go back, tap to confirm. The two-finger tap ends the session from the glasses.")
            }

            #if DEBUG
            MockLensSection()
            FakeStackSection()
            #endif

            Section("Page on the lens") {
                LabeledContent("Page", value: lens.page.title)
                LabeledContent("Species in the stack", value: "\(lens.stack.count)")
                LensCardView(card: lens.card)
            }

            Section("Saved this run") {
                if lens.savedSightings.isEmpty {
                    Text("Nothing saved yet").foregroundStyle(.secondary)
                }
                ForEach(lens.savedSightings) { candidate in
                    LabeledContent(candidate.species.commonName, value: "\(Int((candidate.score * 100).rounded())) %")
                }
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
        .navigationTitle("Lens")
    }

    private var phaseText: String {
        switch lens.phase {
        case .idle: "Not started"
        case .starting: "Starting"
        case .running: "On the lens"
        case .stopping: "Stopping"
        case .stopped(.phone): "Stopped from the phone"
        case .stopped(.back): "Ended with Back"
        case .stopped(.glasses): "Ended by the glasses"
        case .stopped(.failed): "Failed"
        }
    }
}

/// The current card mirrored on the phone (spec "Card renderer": the same page model feeds the phone view).
struct LensCardView: View {
    let card: LensCard

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(card.elements.enumerated()), id: \.offset) { _, element in
                switch element {
                case .heading(let text):
                    Text(text).font(.headline)
                case .body(let text):
                    Text(text)
                case .meta(let text):
                    Text(text).font(.caption).foregroundStyle(.secondary)
                case .image(let image):
                    Label(image.id, systemImage: "photo").font(.caption).foregroundStyle(.secondary)
                case .buttons(let buttons):
                    HStack {
                        ForEach(Array(buttons.enumerated()), id: \.offset) { _, button in
                            Text(button.label)
                                .font(.caption.bold())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(.tint.opacity(button.isPrimary ? 0.3 : 0.1), in: Capsule())
                        }
                    }
                }
            }
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

/// Stands in for the engine: appends the next hard-coded species to the stack.
private struct FakeStackSection: View {
    @Environment(GlassesLensSession.self) private var lens

    var body: some View {
        Section {
            Button("Hear the next species") { lens.update(with: FakeLensStack.stack(count: lens.stack.count + 1)) }
                .disabled(lens.stack.count >= FakeLensStack.species.count)
            Button("Clear the stack") { lens.update(with: CandidateStack()) }
                .disabled(lens.stack.isEmpty)
        } header: {
            Text("Fake stack")
        } footer: {
            Text("Adding a species while on a photo page appends it without moving the page.")
        }
    }
}

private struct MockDisplayPreview: UIViewRepresentable {
    let view: UIView

    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif
