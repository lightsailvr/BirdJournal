import Identification
import Pack
import SwiftUI

/// The run under way (issue #28): the source with its state, the elapsed time, a modest waveform, the species heard
/// with Review or Added on each row, and Stop listening; and, once the run has ended, the same list for the review.
struct ActiveListeningView: View {
    @Environment(ListeningCoordinator.self) private var run
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PaperPage {
            VStack(alignment: .leading, spacing: 0) {
                StatusLine()
                    .padding(.top, 2)

                ElapsedTime(startedAt: run.startedAt, isRunning: run.state.isActive)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 22)

                Waveform(levels: run.waveform, isLive: run.state == .listening && !reduceMotion)
                    .frame(height: 44)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)
                    .accessibilityLabel(run.state == .listening ? "Listening to live audio" : "Audio paused")

                if case .paused(let reason) = run.state {
                    ErrorNotice(reason.phoneTitle, message: reason.phoneText, symbol: "eyeglasses")
                        .padding(.top, 18)
                } else if run.state == .interrupted {
                    ErrorNotice("The glasses ended the session", message: "Checking whether they are off or out of range…", symbol: "eyeglasses")
                        .padding(.top, 18)
                } else if run.state == .resuming {
                    ErrorNotice("Glasses back", message: "Reconnecting to carry on listening…", symbol: "eyeglasses")
                        .padding(.top, 18)
                } else if let message = run.errorMessage, run.state.isActive {
                    ErrorNotice("Something went wrong", message: message)
                        .padding(.top, 18)
                }
                if case .settled(.denied) = run.locationState {
                    LocationNotice(text: "Location is off, so the list is not narrowed to birds that live here. Allow location in Settings to filter it.")
                        .padding(.top, 18)
                } else if case .settled(.unavailable) = run.locationState {
                    LocationNotice(text: "No location fix yet, so the list is not narrowed to birds that live here.")
                        .padding(.top, 18)
                }

                Text(run.summary)
                    .font(JournalFont.body)
                    .foregroundStyle(Color.ink)
                    .padding(.top, 22)
                    .accessibilityAddTraits(.isHeader)

                if run.candidates.isEmpty {
                    HStack(spacing: 10) {
                        if run.state == .starting { ProgressView().tint(Color.moss) }
                        Text(emptyText)
                    }
                    .font(JournalFont.body)
                    .foregroundStyle(Color.inkSecondary)
                    .padding(.top, 16)
                } else {
                    VStack(spacing: 0) {
                        ForEach(run.candidates) { candidate in
                            CandidateRow(candidate: candidate, isAdded: run.isAdded(candidate), startedAt: run.startedAt) {
                                run.reviewing = candidate
                            }
                            RowRule()
                        }
                    }
                    .padding(.top, 12)
                    Text("Possible matches. Add the birds you recognize.")
                        .font(JournalFont.supporting)
                        .foregroundStyle(Color.inkSecondary)
                        .padding(.top, 12)
                }

            }
        }
        .navigationTitle(run.state.isActive ? "Listening" : "Last run")
        .navigationBarTitleDisplayMode(.large)
        // Stop stays where a thumb can reach it, above the tab bar, however long the list grows.
        .safeAreaInset(edge: .bottom) {
            Group {
                if run.state.isActive {
                    Button {
                        Task { await run.stop() }
                    } label: {
                        Label(run.state == .stopping ? "Stopping…" : "Stop listening", systemImage: "stop.fill")
                    }
                    .buttonStyle(.journalPrimary)
                    .disabled(run.state == .stopping || run.state == .starting)
                } else {
                    Button("Done") { run.dismissEnded() }
                        .buttonStyle(.journalPrimary)
                }
            }
            .padding(.horizontal, JournalLayout.margin)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }
}

extension ActiveListeningView {
    /// What the empty list says: what the run is doing until a bird is heard.
    fileprivate var emptyText: String {
        switch run.state {
        case .starting:
            (run.runSource ?? run.source) == .glasses
                ? "Starting: connecting to the glasses, checking camera and microphone access with Meta AI, loading the models…"
                : "Starting: finding your location and loading the models…"
        case .listening: "Listening for birds…"
        case .interrupted, .paused, .resuming: "Waiting for the glasses…"
        case .stopping: "Stopping…"
        case .idle, .ended: "No birds were heard."
        }
    }
}

/// The dot and the source under the title: green while listening, amber while paused, grey once ended.
private struct StatusLine: View {
    @Environment(ListeningCoordinator.self) private var run

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
            Text(text)
                .font(JournalFont.body)
                .foregroundStyle(Color.inkSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch run.state {
        case .listening: .moss
        case .starting, .interrupted, .paused, .resuming, .stopping: .orange
        case .idle, .ended: .inkSecondary
        }
    }

    private var text: String {
        let source = (run.runSource ?? run.source)
        switch run.state {
        case .starting: return "Starting \(source == .glasses ? "the glasses" : "the microphone")…"
        case .listening: return source == .glasses ? "Glasses microphones" : "iPhone microphone"
        case .interrupted, .paused, .resuming: return "\(source.title) · paused"
        case .stopping: return "Stopping…"
        case .ended(.stopped): return "Listening stopped"
        case .ended(.endedByGlasses): return "Ended by the glasses"
        case .ended(.failed): return "Listening stopped"
        case .idle: return source.microphoneText
        }
    }
}

/// Minutes and seconds since the run started, ticking once a second while it runs.
struct ElapsedTime: View {
    let startedAt: Date?
    let isRunning: Bool
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 40

    var body: some View {
        TimelineView(.periodic(from: .now, by: isRunning ? 1 : 3_600)) { context in
            Text(Self.text(from: startedAt, to: context.date))
                .font(.system(size: size, weight: .regular, design: .serif))
                .monospacedDigit()
                .foregroundStyle(Color.ink)
                .accessibilityLabel(Self.spokenText(from: startedAt, to: context.date))
        }
    }

    static func text(from start: Date?, to now: Date) -> String {
        guard let start else { return "00:00" }
        let seconds = max(Int(now.timeIntervalSince(start)), 0)
        if seconds >= 3_600 {
            return String(format: "%d:%02d:%02d", seconds / 3_600, seconds % 3_600 / 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    static func spokenText(from start: Date?, to now: Date) -> String {
        guard let start else { return "Not started" }
        let seconds = max(Int(now.timeIntervalSince(start)), 0)
        return "Listening for \(seconds / 60) minutes \(seconds % 60) seconds"
    }
}

/// A narrow strip of bars following the live level: a picture of the input, not a recording.
struct Waveform: View {
    let levels: [Float]
    let isLive: Bool

    var body: some View {
        GeometryReader { geometry in
            let count = max(levels.count, 1)
            let gap: CGFloat = 3
            let width = max((geometry.size.width - gap * CGFloat(count - 1)) / CGFloat(count), 1)
            HStack(alignment: .center, spacing: gap) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(Color.moss.opacity(isLive ? 0.9 : 0.35))
                        .frame(width: width, height: 4 + CGFloat(level) * (geometry.size.height - 4))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .animation(isLive ? .linear(duration: 0.08) : nil, value: levels)
    }
}

private struct LocationNotice: View {
    @Environment(\.openURL) private var openURL
    let text: String

    var body: some View {
        ErrorNotice("No location", message: text, symbol: "location.slash") {
            if text.contains("Settings") {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
        }
    }
}

/// One species heard: thumbnail, name, when it was last heard, and Review or the Added mark. The row is the same
/// height with and without a photo, and never moves when the scores change.
struct CandidateRow: View {
    @Environment(PackLibrary.self) private var library
    @Environment(\.dynamicTypeSize) private var typeSize
    let candidate: Candidate
    let isAdded: Bool
    let startedAt: Date?
    let review: () -> Void

    var body: some View {
        let reference = library.species(scientificName: candidate.species.scientificName)
        let stacked = typeSize.stacksRows
        AdaptiveRow(stacked: stacked) {
            PackImage(url: reference.flatMap { found in found.species.photos.first.map(found.pack.lensImageURL(for:)) })
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: JournalLayout.thumbnailRadius, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(reference?.species.commonName ?? candidate.species.commonName)
                    .font(JournalFont.rowTitle)
                    .foregroundStyle(Color.ink)
                Text(isAdded ? "Added to journal" : Self.heardText(candidate, startedAt: startedAt, now: .now))
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.inkSecondary)
            }
            if !stacked { Spacer(minLength: 8) }
            if isAdded {
                Button(action: review) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.moss)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Added. Review \(candidate.species.commonName)")
            } else {
                Button("Review", action: review)
                    .buttonStyle(.journalOutlined)
                    .accessibilityLabel("Review \(candidate.species.commonName)")
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture(perform: review)
    }

    /// "Heard just now" within the last minute, else minutes ago, from the run's own clock.
    static func heardText(_ candidate: Candidate, startedAt: Date?, now: Date) -> String {
        guard let startedAt else { return "Heard" }
        let secondsAgo = now.timeIntervalSince(startedAt) - candidate.lastHeardAt
        if secondsAgo < 60 { return "Heard just now" }
        let minutes = Int(secondsAgo / 60)
        if minutes < 60 { return "Heard \(minutes) min ago" }
        return "Heard \(minutes / 60) h \(minutes % 60) min ago"
    }
}
