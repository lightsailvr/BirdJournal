import Foundation

/// What a rear camera says about its zoom (issue #187, of #185), in the camera's own factors, where 1 is its widest view.
/// `PhoneCaptureCamera` reads it from AVFoundation; the tests and the stand-in write one by hand.
nonisolated struct RearCameraFacts: Equatable, Sendable {
    /// One lens behind the camera.
    struct Lens: Equatable, Sendable {
        /// The factor at which this lens takes over: 1 for the first.
        var start: Double
        /// Zoom factors of this lens alone at which its sensor gives a centre crop with no up-scaling: 2 for a 48 MP sensor.
        var fullQualityCrops: [Double] = []
    }

    /// The least and the most the camera can be set to.
    var minimum: Double
    var maximum: Double
    /// The lenses, the widest first.
    var lenses: [Lens]
    /// What a factor is multiplied by to be read by a person: 0.5 where the ultra-wide is the first lens, so the wide reads 1.
    var displayMultiplier: Double = 1
}

/// The capture camera's zoom as a birder reads it: the lens buttons, how far a pinch can go, and where it stands now.
nonisolated struct CaptureZoom: Equatable, Sendable {
    /// The lens buttons, ascending: 0.5, 1, 2, 4 and 8 on an iPhone 17 Pro. Never empty.
    let lenses: [Double]
    /// How far the zoom goes.
    let range: ClosedRange<Double>
    /// Where it stands.
    private(set) var factor: Double
    private let displayMultiplier: Double

    /// A camera with nothing to zoom: one lens at 1.
    static let fixed = CaptureZoom(lenses: [1], range: 1...1, factor: 1, displayMultiplier: 1)

    private init(lenses: [Double], range: ClosedRange<Double>, factor: Double, displayMultiplier: Double) {
        self.lenses = lenses
        self.range = range
        self.factor = factor
        self.displayMultiplier = displayMultiplier
    }

    /// The steps the camera has, and no more: where each lens starts, and each lens's full-quality crop while it is still the
    /// lens in use. The zoom opens on 1, the wide lens, and a pinch goes on to five times the last step, as the phone's own
    /// camera does, or as far as the camera goes.
    init(_ facts: RearCameraFacts) {
        let multiplier = facts.displayMultiplier > 0 ? facts.displayMultiplier : 1
        var steps: [Double] = []
        for (index, lens) in facts.lenses.enumerated() {
            let next = index + 1 < facts.lenses.count ? facts.lenses[index + 1].start : .infinity
            steps.append(lens.start)
            steps += lens.fullQualityCrops.map { lens.start * $0 }.filter { $0 > lens.start && $0 < next }
        }
        let shown = Set(steps.filter { $0 >= facts.minimum && $0 <= facts.maximum }.map { Self.rounded($0 * multiplier) }).sorted()
        let least = Self.rounded(facts.minimum * multiplier)
        let lenses = shown.isEmpty ? [least] : shown
        let most = max(min(facts.maximum * multiplier, lenses[lenses.count - 1] * 5), lenses[lenses.count - 1])
        let range = min(least, lenses[0])...most
        self.init(lenses: lenses, range: range, factor: min(max(1, range.lowerBound), range.upperBound), displayMultiplier: multiplier)
    }

    /// The lens button that is marked: the last step the zoom has reached.
    var currentLens: Double {
        lenses.last { $0 <= factor + 0.005 } ?? lenses[0]
    }

    /// The factor to hand the camera, in its own terms.
    var deviceFactor: Double { factor / displayMultiplier }

    /// Sets the zoom, kept within what the camera can do.
    mutating func set(_ factor: Double) {
        guard factor.isFinite else { return }
        self.factor = min(max(factor, range.lowerBound), range.upperBound)
    }

    /// One step in or out, for VoiceOver's swipe up and down: the next lens, and past the last one, double (or half) at a time.
    func stepped(in zoomsIn: Bool) -> Double {
        let top = lenses[lenses.count - 1]
        if zoomsIn {
            if let next = lenses.first(where: { $0 > factor + 0.005 }) { return next }
            return min(factor * 2, range.upperBound)
        }
        if factor > top + 0.005 { return max(factor / 2, top) }
        return lenses.last { $0 < factor - 0.005 } ?? range.lowerBound
    }

    /// "0.5×", "2×", "2.6×", "12×": one decimal below ten when there is one to show.
    static func text(_ factor: Double) -> String { "\(number(factor))×" }

    /// "2.6 times", for VoiceOver, which reads "×" in its own way.
    static func spoken(_ factor: Double) -> String { "\(number(factor)) times" }

    private static func number(_ factor: Double) -> String {
        let tenths = (factor * 10).rounded() / 10
        if factor >= 10 || tenths == tenths.rounded() { return String(Int(factor >= 10 ? factor.rounded() : tenths)) }
        return String(format: "%.1f", tenths)
    }

    private static func rounded(_ factor: Double) -> Double { (factor * 100).rounded() / 100 }
}
