import CoreGraphics
import Foundation

/// One thread of a patch's stitch-in: a band of the pack's stitch order, the colour it's sewn in, and what the caption
/// calls it. The last band of a patch is its merrowed cord.
nonisolated struct StitchThread: Equatable, Sendable {
    /// The band on the stitch order, 0...1.
    let start: Double
    let end: Double
    /// The swatch, in sRGB 0...1.
    let red: Double
    let green: Double
    let blue: Double
    let isCord: Bool

    var name: String { ThreadName.of(red: red, green: green, blue: blue) }
}

/// The stitch-in's clock (issue #135, guide page 14), pure so its pacing is tested without a screen: about 4.2 s, starting
/// on the bare twill and its transfer pattern, one thread at a time in the pack's order, the cord last with twice a thread's
/// time, since it has the whole way round to go. Every thread gets the same time however much of the patch it fills, so the
/// fine details at the end are still seen.
nonisolated struct StitchTimeline: Sendable {
    /// What the stitch-in shows at one moment.
    struct Frame: Equatable {
        /// How far along the stitch order the thread is laid; under 0 is none of it, 1 or more all of it (`patchLit`).
        let sewnTo: Float
        /// The thread being sewn, nil on the bare twill.
        let thread: Int?
        let isDone: Bool
    }

    static let duration: TimeInterval = 4.2
    /// On the bare twill before the first thread, as parts of the whole. Long enough for a review sheet to finish closing
    /// and the transfer pattern to be seen.
    private static let leadIn = 0.4 / duration
    /// On the finished patch, before the reveal's words take over.
    private static let settle = 0.25 / duration
    private static let cordWeight = 2.0
    private static let bare: Float = -0.02
    /// All of it: past every value of the order, so `patchLit` stops looking at it.
    static let allSewn: Float = 1.01

    let threads: [StitchThread]
    var duration = StitchTimeline.duration
    /// Plays round and round, never done, for measuring (`-stitchInSweep`).
    var loops = false

    func frame(at elapsed: TimeInterval) -> Frame {
        let time = loops ? elapsed.truncatingRemainder(dividingBy: duration) : elapsed
        let position = time / duration
        if !loops, position >= 1 { return Frame(sewnTo: Self.allSewn, thread: threads.indices.last, isDone: true) }
        guard !threads.isEmpty, position >= Self.leadIn else { return Frame(sewnTo: Self.bare, thread: nil, isDone: false) }
        let sewing = (position - Self.leadIn) / (1 - Self.leadIn - Self.settle)
        guard sewing < 1 else { return Frame(sewnTo: Self.allSewn, thread: threads.indices.last, isDone: false) }
        let weights = threads.map { $0.isCord ? Self.cordWeight : 1 }
        var left = sewing * weights.reduce(0, +)
        for (index, thread) in threads.enumerated() {
            if left < weights[index] {
                return Frame(sewnTo: Float(thread.start + (thread.end - thread.start) * left / weights[index]), thread: index, isDone: false)
            }
            left -= weights[index]
        }
        return Frame(sewnTo: Self.allSewn, thread: threads.indices.last, isDone: false)
    }

    /// "Thread 5 of 10 · Ochre", "Cord · Olive"; the transfer pattern on the bare twill.
    func caption(for thread: Int?) -> String {
        guard let thread, threads.indices.contains(thread) else { return "Transfer pattern" }
        let sewn = threads[thread]
        return sewn.isCord ? "Cord · \(sewn.name)" : "Thread \(thread + 1) of \(threads.count) · \(sewn.name)"
    }
}

/// Whether an add gets the stitch-in at all.
nonisolated enum StitchCeremony {
    /// Reduce Motion has no stitching (guide page 14). Nor does VoiceOver: nothing in it can be spoken, so it would be four
    /// seconds of waiting on a page that says nothing new, and the finished page says it all at once. Without a painting on
    /// the phone there's nothing to stitch.
    static func stitches(reduceMotion: Bool, voiceOver: Bool, hasArt: Bool) -> Bool {
        hasArt && !reduceMotion && !voiceOver
    }
}

/// Plain words for a thread's colour: the pack orders its threads but doesn't name them, so the caption names what it sees.
nonisolated enum ThreadName {
    static func of(red: Double, green: Double, blue: Double) -> String {
        let (top, bottom) = (max(red, green, blue), min(red, green, blue))
        let lightness = (top + bottom) / 2
        let chroma = top - bottom
        if lightness < 0.13 { return "Black" }
        if chroma < 0.08 {
            return lightness < 0.35 ? "Charcoal" : lightness < 0.7 ? "Grey" : lightness < 0.9 ? "Silver" : "White"
        }
        let hue: Double = switch top {
        case red: ((green - blue) / chroma + 6).truncatingRemainder(dividingBy: 6) * 60
        case green: ((blue - red) / chroma + 2) * 60
        default: ((red - green) / chroma + 4) * 60
        }
        switch hue {
        case ..<15, 345...: return lightness < 0.35 ? "Oxblood" : lightness < 0.65 ? "Red" : "Rose"
        case ..<40: return lightness < 0.3 ? "Umber" : lightness < 0.45 ? "Rust" : lightness < 0.72 ? "Ochre" : "Sand"
        case ..<70: return lightness < 0.42 ? "Olive" : lightness < 0.72 ? "Straw" : "Cream"
        case ..<170: return lightness < 0.35 ? "Forest" : lightness < 0.6 ? "Moss" : "Sage"
        case ..<260: return lightness < 0.35 ? "Navy" : lightness < 0.65 ? "Slate blue" : "Sky"
        default: return lightness < 0.45 ? "Plum" : "Lilac"
        }
    }
}

extension StitchThread {
    /// A patch's threads, read from its decoded pictures: for each band of the stitch order the commonest colour among its
    /// pixels. Not their mean, which would average a band's grain to mud. A band too small to see is left out, so no tick
    /// and no caption goes by with nothing happening; its few pixels come in with the next thread.
    ///
    /// Both pictures are `PatchTextures.bitmap`'s: 8-bit RGBA, premultiplied, the layers at half the colour's size.
    nonisolated static func threads(colour: CGImage, layers: CGImage, bounds: [Int]) -> [StitchThread] {
        guard bounds.count >= 2,
              let colourData = colour.dataProvider?.data, let layersData = layers.dataProvider?.data,
              let colourBytes = CFDataGetBytePtr(colourData), let layerBytes = CFDataGetBytePtr(layersData)
        else { return [] }
        let bands = bounds.count - 1
        var bandOfOrder = [Int](repeating: 0, count: 256)
        for order in 0..<256 { bandOfOrder[order] = min(bounds.lastIndex { $0 <= order } ?? 0, bands - 1) }
        // Sixteen levels a channel: fine enough to tell threads apart, coarse enough that a thread's grain falls in one.
        struct Bucket { var count = 0, red = 0, green = 0, blue = 0 }
        let levels = 4096
        var buckets = [Bucket](repeating: Bucket(), count: bands * levels)
        var inside = 0
        for y in 0..<layers.height {
            let sourceY = min(y * colour.height / layers.height, colour.height - 1)
            for x in 0..<layers.width {
                let sourceX = min(x * colour.width / layers.width, colour.width - 1)
                let pixel = colourBytes + sourceY * colour.bytesPerRow + sourceX * 4
                let alpha = Int(pixel[3])
                guard alpha > 128 else { continue }
                inside += 1
                let band = bandOfOrder[Int(layerBytes[y * layers.bytesPerRow + x * 4 + 2])]
                let (red, green, blue) = (Int(pixel[0]) * 255 / alpha, Int(pixel[1]) * 255 / alpha, Int(pixel[2]) * 255 / alpha)
                let at = band * levels + ((red >> 4) << 8 | (green >> 4) << 4 | blue >> 4)
                buckets[at].count += 1
                buckets[at].red += red
                buckets[at].green += green
                buckets[at].blue += blue
            }
        }
        let smallest = max(inside / 1000, 1)
        return (0..<bands).compactMap { band in
            let own = buckets[(band * levels)..<((band + 1) * levels)]
            let total = own.reduce(0) { $0 + $1.count }
            let isCord = band == bands - 1
            guard total >= (isCord ? 1 : smallest), let common = own.max(by: { $0.count < $1.count }) else { return nil }
            let scale = Double(common.count) * 255
            return StitchThread(
                start: Double(bounds[band]) / 255, end: Double(bounds[band + 1]) / 255,
                red: Double(common.red) / scale, green: Double(common.green) / scale, blue: Double(common.blue) / scale, isCord: isCord
            )
        }
    }
}
