import AppIntents
import SwiftUI
import WidgetKit

/// The run on the Lock Screen (issue #150): plain iOS you operate, with the edition's tint on what matters. It draws only the
/// snapshot. The time comes from the system's own timer text, which ticks without an update from the app.
struct RunActivityClock: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    let snapshot: RunSnapshot
    var font: Font = .system(.title, design: .serif)

    var body: some View {
        Group {
            if let startedAt = snapshot.startedAt {
                Text(timerInterval: startedAt...Date.distantFuture, pauseTime: snapshot.pausedAt, countsDown: false)
            } else {
                Text("–:––")
                    .accessibilityLabel(snapshot.statusText)
            }
        }
        .font(font)
        .monospacedDigit()
        .foregroundStyle(GlanceInk.ink(scheme, contrast))
    }
}

/// Stop, as quiet as the run's Stop: a bordered button in the tint.
struct RunActivityStop: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    let snapshot: RunSnapshot

    var body: some View {
        Button(intent: StopRunIntent()) {
            Label("Stop", systemImage: "stop.fill")
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 30)
        }
        .buttonStyle(.bordered)
        .tint(GlanceInk.tint(setID: snapshot.setID, scheme, contrast))
        .disabled(snapshot.phase == .stopping)
        .accessibilityLabel("Stop listening")
    }
}

/// "3 birds heard", and "1 new patch waiting" in the tint, which is the point of the run.
struct RunActivityCounts: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    let snapshot: RunSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(snapshot.birdsHeardText)
                .foregroundStyle(GlanceInk.secondary(scheme, contrast))
            if let new = snapshot.newPatchesText {
                Text(new)
                    .fontWeight(.semibold)
                    .foregroundStyle(GlanceInk.tint(setID: snapshot.setID, scheme, contrast))
            }
        }
        .font(.subheadline)
        .lineLimit(2)
        .minimumScaleFactor(0.85)
    }
}

struct RunLockScreenView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    let snapshot: RunSnapshot
    /// No word from the app for a while: it may have been killed mid-run. Stop clears it either way.
    var isStale = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .foregroundStyle(GlanceInk.tint(setID: snapshot.setID, scheme, contrast))
                    .accessibilityHidden(true)
                Text(isStale ? "Open Featherguild to check this run" : snapshot.statusText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(GlanceInk.secondary(scheme, contrast))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    RunActivityClock(snapshot: snapshot)
                    RunActivityCounts(snapshot: snapshot)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                RunActivityStop(snapshot: snapshot)
            }
        }
        .padding(16)
        // A fixed-size surface: the words are in the app at any size.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityElement(children: .contain)
    }
}

/// The Dynamic Island's expanded parts, here so the debug preview draws them too.
struct RunIslandExpandedLeading: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    let snapshot: RunSnapshot

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform")
                .foregroundStyle(GlanceInk.tint(setID: snapshot.setID, scheme, contrast))
                .accessibilityLabel(snapshot.statusText)
            RunActivityClock(snapshot: snapshot, font: .system(.title2, design: .serif))
        }
        .padding(.leading, 4)
    }
}

/// The Island's other corner: what the run is doing, in its own contrast.
struct RunIslandStatus: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    let snapshot: RunSnapshot

    var body: some View {
        Text(snapshot.statusText)
            .font(.subheadline)
            .foregroundStyle(GlanceInk.secondary(scheme, contrast))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

/// Under the Island's top line: the counts, on a line they fit, and Stop.
struct RunIslandExpandedBottom: View {
    let snapshot: RunSnapshot

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            RunActivityCounts(snapshot: snapshot)
                .frame(maxWidth: .infinity, alignment: .leading)
            RunActivityStop(snapshot: snapshot)
        }
        .padding(.horizontal, 4)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }
}

struct RunIslandCompactLeading: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    let snapshot: RunSnapshot

    var body: some View {
        Image(systemName: snapshot.phase == .paused ? "pause.fill" : "waveform")
            .foregroundStyle(GlanceInk.tint(setID: snapshot.setID, scheme, contrast))
            .accessibilityLabel(snapshot.spokenText)
    }
}

/// The time, or the number of new patches once there are any: the Island has room for one, and that's the one to look up for.
struct RunIslandCompactTrailing: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    let snapshot: RunSnapshot

    var body: some View {
        if snapshot.newPatchesWaiting > 0 {
            Text("+\(snapshot.newPatchesWaiting)")
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(GlanceInk.tint(setID: snapshot.setID, scheme, contrast))
                .accessibilityLabel(snapshot.newPatchesText ?? "")
        } else {
            RunActivityClock(snapshot: snapshot, font: .body)
                .frame(maxWidth: 52)
                .multilineTextAlignment(.trailing)
        }
    }
}
