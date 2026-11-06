import SwiftUI

/// A row of `count` stitches, the first `sewn` of them drawn: a whole number at rest, and between two while it's sewing, so a
/// stitch runs out along its length. `ThreadProgress`'s thread, and `GlanceProgress`'s, which the widget extension can reach.
nonisolated struct Stitches: Shape {
    let count: Int
    var sewn: Double

    /// The mock's 3 px thread at 1.34: 8 on and 3 off.
    private static let lengthOverHeight: CGFloat = 8.0 / 3

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

    /// How many stitches a row of `width` holds.
    static func count(width: CGFloat, height: CGFloat) -> Int {
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
}
