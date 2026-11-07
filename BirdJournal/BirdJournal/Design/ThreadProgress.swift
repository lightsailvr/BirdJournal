import Album
import SwiftUI

/// The one progress bar (issue #150): a running stitch in the edition's thread, or lavender for a goal. When the value rises
/// it sews forward a stitch at a time, and a rise it wasn't there for (a bird added during a run, a bird added while another tab
/// was showing) sews the next time it's on screen. Under Reduce Motion it jumps. Any progress above zero shows at least one
/// stitch, and the last stitch waits for the whole. VoiceOver reads `sentence`: where the row around it already says the count,
/// hide it from VoiceOver at the call. It takes no touches, and it's never the face of a button (the design guide's no fake
/// stitching).
///
///     ThreadProgress(setProgress)                                                    // the set's own edition
///     ThreadProgress(goal: goal, circleID: id)                                       // lavender, on the page or felt
///     ThreadProgress(goal: goal, circleID: id, thread: .onLavender)                  // on a lavender card
///     ThreadProgress(value: got, total: size, sentence: "…", thread: .edition(setID: id))
struct ThreadProgress: View {
    enum Thread: Equatable {
        /// One set's edition; nil is Uncharted.
        case edition(setID: String?)
        /// Lavender, on the page or felt: "together".
        case together
        /// Lavender's ink, on a lavender card.
        case onLavender
    }

    let value: Double
    let total: Double
    let sentence: String
    let thread: Thread
    /// Counted birds show their first two stitches as they're found, so a set's first birds each sew one (the mock's "3 of 160").
    private var countsBirds = false
    /// Names what's being counted, so a rise sews once, wherever it's next seen. A download has none: its row stays up.
    private var memoryKey: String?

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .subheadline) private var scaledHeight = ThreadProgress.height
    /// The stitches drawn: behind the value for as long as it's sewing towards it.
    @State private var shown: Double?
    @State private var isOnScreen = false
    @Environment(ListeningCoordinator.self) private var run: ListeningCoordinator?
    /// What the haptics follow as it sews: one tick a stitch, and the last stitch's success.
    @State private var ticks = 0
    @State private var finishes = 0
    @State private var felt: Task<Void, Never>?

    /// The mock's 3 px thread at 1.34: 8 on and 3 off.
    static let height: CGFloat = 4
    private static let secondsPerStitch = 0.07
    /// Past a tab change or a push, so the sewing is seen.
    private static let settle = Duration.milliseconds(350)

    /// The value each counted thing last showed on screen, this launch.
    static var lastSeen: [String: Double] = [:]

    init(value: Double, total: Double, sentence: String, thread: Thread) {
        self.value = value
        self.total = total
        self.sentence = sentence
        self.thread = thread
    }

    /// A set's birds, in its own edition's thread.
    init(_ progress: SetProgress) {
        value = Double(progress.collected)
        total = Double(progress.total)
        sentence = "\(progress.sewnText) in \(progress.name)"
        thread = .edition(setID: progress.setID)
        countsBirds = true
        memoryKey = "set-\(progress.setID)"
    }

    /// A goal's birds, in lavender. `circleID` names whose: a monthly goal's id is only its month, the same in every Guild, so without
    /// it one Guild's thread would sew from where another's was last seen.
    init(goal: CircleGoal, circleID: String, thread: Thread = .together) {
        value = Double(goal.progress)
        total = Double(goal.target)
        sentence = GoalWords.sentence(goal)
        self.thread = thread
        countsBirds = true
        memoryKey = "goal-\(circleID)-\(goal.id)"
    }

    /// How many stitches a row of `width` holds.
    static func stitches(width: CGFloat, height: CGFloat = ThreadProgress.height) -> Int {
        Stitches.count(width: width, height: height)
    }

    /// How many of `stitches` are sewn: the share, rounded, with at least one above zero and the last only at the whole.
    /// `countsBirds` gives the first two birds a stitch each.
    static func sewn(value: Double, total: Double, stitches: Int, countsBirds: Bool = false) -> Int {
        Stitches.sewn(value: value, total: total, stitches: stitches, countsBirds: countsBirds)
    }

    /// Where a thread starts as it comes on screen: at the stitch it last showed, if the value has risen since, so it sews the
    /// rest; else at the value. With nothing seen yet, or under Reduce Motion, there's nothing to sew.
    static func startingStitches(lastSeen: Double?, value: Double, total: Double, stitches: Int, countsBirds: Bool, isStill: Bool) -> Int {
        let now = sewn(value: value, total: total, stitches: stitches, countsBirds: countsBirds)
        guard let lastSeen, lastSeen < value, !isStill else { return now }
        return sewn(value: lastSeen, total: total, stitches: stitches, countsBirds: countsBirds)
    }

    private var stitchHeight: CGFloat { min(scaledHeight, 8) }
    private var isStill: Bool { PatchMotion.reduces(system: systemReduceMotion) }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            if width > 0 {
                let count = Self.stitches(width: width, height: stitchHeight)
                let sewn = Self.sewn(value: value, total: total, stitches: count, countsBirds: countsBirds)
                ZStack {
                    Stitches(count: count, sewn: Double(count)).fill(trackColor)
                    sewnStitches(count: count, sewn: shown ?? Double(sewn))
                }
                .onAppear {
                    isOnScreen = true
                    let start = Self.startingStitches(lastSeen: memoryKey.flatMap { Self.lastSeen[$0] }, value: value, total: total, stitches: count, countsBirds: countsBirds, isStill: isStill)
                    remember()
                    shown = Double(start)
                    if start < sewn {
                        Task {
                            try? await Task.sleep(for: Self.settle)
                            sew(from: start, to: sewn)
                        }
                    }
                }
                .onDisappear { isOnScreen = false }
                // A rise off screen waits for `onAppear`. A fall (an Undo) unpicks at once.
                .onChange(of: value) { old, new in
                    guard isOnScreen else { return }
                    remember()
                    if new > old, !isStill {
                        sew(from: Int(shown ?? 0), to: sewn)
                    } else {
                        shown = Double(sewn)
                    }
                }
                // A row that's changed size isn't progress.
                .onChange(of: count) { shown = Double(sewn) }
            }
        }
        .frame(height: stitchHeight)
        .haptic(.stitchTick, trigger: ticks) { _, _ in Haptic.ticks(phoneRunHoldsSession: run?.phoneRunHoldsSession ?? false) }
        .haptic(.stitchDone, trigger: finishes)
        .onDisappear { felt?.cancel() }
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel(sentence)
    }

    private func remember() {
        if let memoryKey { Self.lastSeen[memoryKey] = value }
    }

    private func sew(from start: Int, to end: Int) {
        guard end > start else { return }
        let duration = min(Double(end - start) * Self.secondsPerStitch, 1)
        withAnimation(.linear(duration: duration)) { shown = Double(end) }
        // Birds being counted say so as they're sewn. A download's thread doesn't: it's creeping along by itself.
        guard countsBirds else { return }
        felt?.cancel()
        felt = Task { @MainActor in
            let each = Duration.seconds(duration / Double(end - start))
            for _ in start..<(end - 1) {
                try? await Task.sleep(for: each)
                guard !Task.isCancelled else { return }
                ticks += 1
            }
            try? await Task.sleep(for: each)
            guard !Task.isCancelled else { return }
            finishes += 1
        }
    }

    @ViewBuilder
    private func sewnStitches(count: Int, sewn: Double) -> some View {
        let stitches = Stitches(count: count, sewn: sewn)
        switch thread {
        case .edition(let setID): stitches.fill(PatchEdition.tint(setID: setID))
        case .together: stitches.fill(Color.togetherThread)
        case .onLavender: stitches.fill(Color.onSharedGoal)
        }
    }

    /// The stitches still to sew, as the mock draws them: faint, and stronger under Increase Contrast.
    private var trackColor: Color {
        (thread == .onLavender ? Color.onSharedGoal : Color.ink).opacity(contrast == .increased ? 0.4 : 0.22)
    }
}
