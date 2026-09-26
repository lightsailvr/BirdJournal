import Identification
import MWDATCamera
import SwiftUI

/// Phase A spike screen: pick a source, start, lock the phone, come back and share the log.
struct SpikeView: View {
    @Environment(GlassesConnection.self) private var connection
    @Environment(SpikeRecorder.self) private var recorder
    @State private var sourceKind: SpikeSourceKind = .glasses
    @State private var sampleRate: AudioSampleRate = .rate48000

    var body: some View {
        List {
            Section {
                Picker("Source", selection: $sourceKind) {
                    ForEach(SpikeSourceKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(recorder.isRunning)
                if sourceKind == .glasses {
                    // DECISIONS.md leaves 44.1 vs 48 kHz to this spike.
                    Picker("Sample rate", selection: $sampleRate) {
                        Text("44.1 kHz").tag(AudioSampleRate.rate44100)
                        Text("48 kHz").tag(AudioSampleRate.rate48000)
                    }
                    .disabled(recorder.isRunning)
                }

                if recorder.isStarting {
                    HStack {
                        ProgressView()
                        Text("Starting…")
                    }
                } else if recorder.isRunning {
                    Button("Stop", role: .destructive) { Task { await recorder.stop() } }
                } else {
                    Button("Start") { Task { await recorder.start(sourceKind, sampleRate: sampleRate) } }
                }

                if let errorMessage = recorder.errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
                if connection.glassesAppUpdateRequired {
                    Button("Update the glasses app") { Task { await connection.openGlassesAppUpdate() } }
                }
            } footer: {
                Text("Starting the glasses source may open Meta AI to grant camera and microphone access. Status is logged every 30 seconds; lock the phone and keep it in a pocket for 20 minutes.")
            }

            if let summary = recorder.latestSummary {
                Section("Last 30 seconds") {
                    LabeledContent("Chunks", value: "\(summary.chunks)")
                    LabeledContent("Audio", value: summary.audioSeconds.formatted(.number.precision(.fractionLength(1))) + " s")
                    LabeledContent("Longest interval", value: milliseconds(summary.maxInterval))
                    LabeledContent("Latency above best", value: milliseconds(summary.latencyMax))
                    LabeledContent("Gaps (total)", value: "\(summary.gaps) (\(summary.totalGaps))")
                }
            }

            if !recorder.logFiles.isEmpty {
                Section("Logs") {
                    ForEach(recorder.logFiles, id: \.self) { url in
                        ShareLink(item: url) {
                            Label(url.lastPathComponent, systemImage: url == recorder.logURL ? "doc.text.fill" : "doc.text")
                        }
                    }
                }
            }

            Section("Live") {
                ForEach(Array(recorder.recentLines.reversed().enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced())
                }
            }
        }
        .navigationTitle("Audio spike")
    }

    private func milliseconds(_ seconds: Double?) -> String {
        seconds.map { ($0 * 1_000).formatted(.number.precision(.fractionLength(0))) + " ms" } ?? "–"
    }
}
