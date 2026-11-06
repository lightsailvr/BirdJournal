import Album
import SwiftUI

/// The one progress bar (issue #150): a running stitch in the edition's thread, or lavender for a goal. When the value rises
/// it sews forward a stitch at a time; under Reduce Motion it jumps. Any progress above zero shows at least one stitch, and
/// the last stitch waits for the whole. VoiceOver reads `sentence`: where the row beside it already says the count, hide it
/// from VoiceOver at the call. It takes no touches, and it's never the face of a button (the design guide's no fake stitching).
///
///     ThreadProgress(setProgress)                                  // the set's own edition
///     ThreadProgress(goal: goal, thread: .together)                // lavender on the page; .onLavender on the goal card
///     ThreadProgress(value: received, total: size, sentence: "…")  // the accent where it's drawn
struct ThreadProgress: View {
    enum Thread: Equatable {
        /// The accent where it's drawn: the place's, or the page's own edition.
        case tint
        /// One set's edition, whatever the accent is here.
        case edition(setID: String?)
        /// Lavender, on the page or felt: "together".
        case together
        /// Lavender's ink, on a lavender card.
        case onLavender
    }

    let value: Double
    let total: Double
    let sentence: String
    var thread = Thread.tint
    /// Counted birds show their first two stitches as they're found, so a set's first birds each sew one (the mock's "3 of 160").
    var countsBirds = false

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .subheadline) private var scaledHeight = ThreadProgress.height
    /// What's drawn: behind `sewn` for as long as it's sewing towards it.
    @State private var shown: Double?

    /// The mock's 3 px thread at 1.34: 8 on and 3 off.
    static let height: CGFloat = 4
    private static let lengthOverHeight: CGFloat = 8.0 / 3
    private static let secondsPerStitch = 0.07

    init(value: Double, total: Double, sentence: String, thread: Thread = .tint) {
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
    }

    /// A goal's birds, in lavender.
    init(goal: CircleGoal, thread: Thread = .together) {
        value = Double(goal.progress)
        total = Double(goal.target)
        sentence = GoalWords.sentence(goal)
        self.thread = thread
        countsBirds = true
    }

    /// How many stitches a row of `width` holds.
    static func stitches(width: CGFloat, height: CGFloat = ThreadProgress.height) -> Int {
        max(1, Int((width + height) / (height * lengthOverHeight + height)))
    }

    /// How many of `stitches` are sewn: the share, rounded, with at least one above zero and the last only at the whole.
    /// `countsBirds` gives the first two birds a stitch each.
    static func sewn(value: Double, total: Double, stitches: Int, countsBirds: Bool = false) -> Int {
        guard total > 0, value > 0 else { return 0 }
        guard value < total else { return stitches }
        let share = Int((value / total * Double(stitches)).rounded())
        let leastForThis = countsBirds ? min(Int(value), 2) : 1
        return min(max(share, max(leastForThis, 1)), max(stitches - 1, 1))
    }

    private var stitchHeight: CGFloat { min(scaledHeight, 8) }

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
                .onAppear { shown = Double(sewn) }
                .onChange(of: sewn) { old, new in
                    let isStill = PatchMotion.reduces(system: systemReduceMotion)
                    if new > old, !isStill {
                        withAnimation(.linear(duration: min(Double(new - old) * Self.secondsPerStitch, 1))) { shown = Double(new) }
                    } else {
                        shown = Double(new)
                    }
                }
            }
        }
        .frame(height: stitchHeight)
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel(sentence)
    }

    @ViewBuilder
    private func sewnStitches(count: Int, sewn: Double) -> some View {
        let stitches = Stitches(count: count, sewn: sewn)
        switch thread {
        case .tint: stitches.fill(.tint)
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

/// A row of `count` stitches, the first `sewn` of them drawn: a whole number at rest, and between two while it's sewing, so a
/// stitch runs out along its length.
private nonisolated struct Stitches: Shape {
    let count: Int
    var sewn: Double

    var animatableData: Double {
        get { sewn }
        set { sewn = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let gap = rect.height
        let length = (rect.width - gap * CGFloat(count - 1)) / CGFloat(count)
        for index in 0..<count where Double(index) < sewn {
            let part = CGFloat(min(1, sewn - Double(index)))
            let stitch = CGRect(x: rect.minX + CGFloat(index) * (length + gap), y: rect.minY, width: length * part, height: rect.height)
            path.addRoundedRect(in: stitch, cornerSize: CGSize(width: rect.height / 4, height: rect.height / 4))
        }
        return path
    }
}
