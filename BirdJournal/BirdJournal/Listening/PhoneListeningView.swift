import Identification
import SwiftUI

/// Listening on the phone with no glasses (issue #6): Start, the location state, and the live candidate list.
struct PhoneListeningView: View {
    @Environment(ListeningSession.self) private var session

    var body: some View {
        List {
            Section {
                switch session.phase {
                case .idle:
                    Button("Start listening") { Task { await session.start() } }
                case .starting:
                    HStack {
                        ProgressView()
                        Text("Starting…")
                    }
                case .listening:
                    Button("Stop", role: .destructive) { Task { await session.stop() } }
                case .stopping:
                    HStack {
                        ProgressView()
                        Text("Stopping…")
                    }
                }
                if let errorMessage = session.errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
                LocationRow(session: session)
            } footer: {
                Text("Uses the phone microphone. Powered by BirdNET.")
            }

            HeardSection(session: session)
            ListeningStatsSection(session: session)
        }
        .navigationTitle("Listen")
    }
}

/// The live candidate list (spec user story 34), shared by the phone and glasses screens.
struct HeardSection: View {
    let session: ListeningSession

    var body: some View {
        Section(session.stack.isEmpty ? "Heard" : "Heard (\(session.stack.count))") {
            if session.list.isEmpty {
                Text(session.phase == .listening ? "Listening for birds…" : "No species yet")
                    .foregroundStyle(.secondary)
            }
            ForEach(session.list.rows) { candidate in
                DiagnosticCandidateRow(candidate: candidate)
            }
        }
        .animation(.default, value: session.list.rows.map(\.id))
    }
}

/// Start time and the engine's window count, once a run has scored anything.
struct ListeningStatsSection: View {
    let session: ListeningSession

    var body: some View {
        if session.phase == .listening || session.windowsScored > 0 {
            Section("Session") {
                if let startedAt = session.startedAt {
                    LabeledContent("Started", value: startedAt, format: .dateTime.hour().minute().second())
                }
                LabeledContent("Windows scored", value: "\(session.windowsScored)")
                if let window = session.lastWindow {
                    LabeledContent("Last window", value: lastWindowText(window))
                }
            }
        }
    }

    private func lastWindowText(_ window: WindowReport) -> String {
        let top = window.topSpecies.map { "\($0.commonName) \(window.topScore.formatted(.number.precision(.fractionLength(2))))" } ?? "none"
        return "\(top), \(window.inference.formatted(.units(allowed: [.milliseconds])))"
    }
}

/// The location state as the screen shows it.
struct LocationRow: View {
    @Environment(\.openURL) private var openURL
    let session: ListeningSession

    var body: some View {
        switch session.locationState {
        case .unknown:
            EmptyView()
        case .requesting:
            LabeledContent("Location", value: "Finding you…")
        case .settled(.fix(let latitude, let longitude, _, let at)):
            LabeledContent("Location") {
                VStack(alignment: .trailing) {
                    Text("\(coordinate(latitude)), \(coordinate(longitude))")
                    Text(at, format: .dateTime.hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .settled(.denied):
            VStack(alignment: .leading, spacing: 4) {
                Label("No location", systemImage: "location.slash")
                Text("Species are not filtered by region. Allow location in Settings to narrow the list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .font(.caption)
            }
        case .settled(.unavailable):
            VStack(alignment: .leading, spacing: 4) {
                Label("No location fix", systemImage: "location.slash")
                Text("Species are not filtered by region until a fix arrives.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func coordinate(_ degrees: Double) -> String {
        degrees.formatted(.number.precision(.fractionLength(2))) + "°"
    }
}

private struct DiagnosticCandidateRow: View {
    let candidate: Candidate

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.species.commonName).font(.headline)
                Text(candidate.species.scientificName)
                    .font(.caption)
                    .italic()
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Double(candidate.score), format: .percent.precision(.fractionLength(0)))
                    .font(.headline.monospacedDigit())
                Text("heard \(candidate.windowsAboveThreshold)×")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
