import Identification
import LensSession
import MWDATCamera
import MWDATCore
import MWDATInputs
import SwiftUI

/// The glasses screen (issue #9): start the whole loop, then pocket the phone. Shows the run's states, the live
/// list, the card on the lens and the sightings saved this run.
struct GlassesListeningView: View {
    @Environment(GlassesConnection.self) private var connection
    @Environment(GlassesListeningSession.self) private var run

    var body: some View {
        List {
            Section {
                switch run.phase {
                case .starting:
                    HStack {
                        ProgressView()
                        Text("Starting…")
                    }
                case .listening:
                    Button("Stop", role: .destructive) { Task { await run.stop() } }
                case .stopping:
                    HStack {
                        ProgressView()
                        Text("Stopping…")
                    }
                case .idle, .stopped:
                    Button("Start listening on the glasses") { Task { await run.start() } }
                }
                LabeledContent("Run", value: phaseText)
                if let errorMessage = run.errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
                if connection.glassesAppUpdateRequired {
                    Button("Update the glasses app") { Task { await connection.openGlassesAppUpdate() } }
                }
                LocationRow(session: run.listening)
            } footer: {
                Text("Glasses audio feeds BirdNET; cards show on the lens. Swipe between species, scroll a card for its field marks, tap for \"This is my bird\". Powered by BirdNET.")
            }

            Section("On the lens") {
                LabeledContent("Page", value: run.lens.page.title)
                LensCardView(card: run.lens.card)
                LabeledContent("Session", value: run.sessionState.description)
                LabeledContent("Stream", value: String(describing: run.streamState))
                LabeledContent("Display", value: String(describing: run.lens.displayState))
                LabeledContent("Inputs", value: run.lens.inputsState.description)
            }

            Section("Saved this run") {
                if run.saved.isEmpty {
                    Text("Nothing saved yet").foregroundStyle(.secondary)
                }
                ForEach(run.saved) { sighting in
                    LabeledContent(sighting.candidate.species.commonName) {
                        HStack(spacing: 6) {
                            if sighting.hasFrame { Image(systemName: "camera") }
                            Text(LensCardRenderer.confidence(sighting.candidate))
                        }
                    }
                }
            }

            HeardSection(session: run.listening)
            ListeningStatsSection(session: run.listening)
        }
        .navigationTitle("Glasses")
    }

    private var phaseText: String {
        switch run.phase {
        case .idle: "Not started"
        case .starting: "Starting"
        case .listening: "Listening"
        case .stopping: "Stopping"
        case .stopped(.phone): "Stopped from the phone"
        case .stopped(.back): "Ended with Back"
        case .stopped(.glasses): "Ended by the glasses"
        case .stopped(.failed): "Failed"
        }
    }
}
