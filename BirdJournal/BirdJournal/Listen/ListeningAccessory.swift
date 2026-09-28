import SwiftUI

/// The compact listening strip above the tab bar while a run is active and another tab is showing: the state, the
/// elapsed time and Stop. Tapping the rest of it goes to the Listen tab.
struct ListeningAccessory: View {
    @Environment(ListeningCoordinator.self) private var run
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let showListen: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: showListen) {
                HStack(spacing: 10) {
                    Image(systemName: run.state == .listening ? "waveform" : "pause.circle")
                        .foregroundStyle(Color.moss)
                        .symbolEffect(.variableColor.iterative, isActive: run.state == .listening && !reduceMotion)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(JournalFont.supporting.weight(.semibold))
                            .foregroundStyle(Color.ink)
                        if placement != .inline {
                            Text(run.summary)
                                .font(.caption)
                                .foregroundStyle(Color.inkSecondary)
                        }
                    }
                    Spacer(minLength: 4)
                    ElapsedTimeCompact(startedAt: run.startedAt)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title). \(run.summary). Show the Listen tab.")

            Button {
                Task { await run.stop() }
            } label: {
                Image(systemName: "stop.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.mossText)
                    .frame(width: 40, height: 40)
                    .background(Color.moss, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(run.state == .stopping || run.state == .starting)
            .accessibilityLabel("Stop listening")
        }
        .padding(.horizontal, 14)
    }

    private var title: String {
        switch run.state {
        case .listening: "Listening"
        case .starting: "Starting…"
        case .interrupted, .paused, .resuming: "Paused"
        case .stopping: "Stopping…"
        case .idle, .ended: "Listening stopped"
        }
    }
}

private struct ElapsedTimeCompact: View {
    let startedAt: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(ElapsedTime.text(from: startedAt, to: context.date))
                .font(JournalFont.supporting.monospacedDigit())
                .foregroundStyle(Color.inkSecondary)
        }
    }
}
