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
                Text("Swipe left and right between species, down for a card's field marks and up to come back, tap for \"This is my bird\". The two-finger tap ends the session from the glasses.")
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
                // The same species can be saved more than once in a run, so rows are keyed by position.
                ForEach(Array(lens.savedSightings.enumerated()), id: \.offset) { _, candidate in
                    LabeledContent(candidate.species.commonName, value: LensCardRenderer.confidence(candidate))
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

extension LensPage {
    /// The page as the phone screen names it.
    var title: String {
        switch self {
        case .list(let screenful): "Species list · screenful \(screenful + 1)"
        case .species(let index, let screenful): "Species \(index + 1) · screenful \(screenful + 1)"
        }
    }
}

/// The current card mirrored on the phone (spec "Card renderer": the same page model feeds the phone view), one
/// block per screenful.
struct LensCardView: View {
    let card: LensCard

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(card.screenfuls.enumerated()), id: \.offset) { position, screenful in
                if position > 0 { Divider() }
                ForEach(Array(screenful.enumerated()), id: \.offset) { _, element in
                    LensElementView(element: element)
                }
            }
        }
    }
}

private struct LensElementView: View {
    let element: LensElement

    var body: some View {
        Group {
                switch element {
                case .status(let text):
                    Text(text).font(.caption2).foregroundStyle(.secondary)
                case .photo(let photo):
                    Label(photo.id, systemImage: "photo").font(.caption).foregroundStyle(.secondary)
                case .title(let name, let detail):
                    HStack(alignment: .firstTextBaseline) {
                        Text(name).font(.headline)
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                case .heading(let text):
                    Text(text).font(.headline)
                case .body(let text):
                    Text(text)
                case .meta(let text):
                    Text(text).font(.caption).foregroundStyle(.secondary)
                case .button(let button):
                    Text(button.label)
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.tint.opacity(button.isPrimary ? 0.3 : 0.1), in: Capsule())
                case .saved(let text):
                    Label(text, systemImage: "checkmark.circle.fill").font(.caption.bold())
                case .list(let rows):
                    ForEach(rows, id: \.index) { row in
                        HStack {
                            Text(row.commonName)
                            Text(row.confidence).font(.caption).foregroundStyle(.secondary)
                            if row.hasPhoto { Image(systemName: "photo").font(.caption) }
                            if row.isSaved { Image(systemName: "checkmark.circle.fill").font(.caption) }
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
            Text("Adding a species while on a card appends it without moving the page.")
        }
    }
}

private struct MockDisplayPreview: UIViewRepresentable {
    let view: UIView

    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif
