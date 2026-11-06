import Pack
import SwiftUI
import UIKit

/// A designed landscape (issue #118, design guide pages 3–4, 13 and 14): each Guild's habitat cover.
/// Flat watercolour-toned layers (sky, a soft sun, ridges and the habitat's own marks) in natural colours that stay
/// the same in both appearances, as the bird art does. Illustrative only: never a map, never a sighting's place.
/// Still: no parallax, no motion.
enum Landscape: String, CaseIterable, Sendable {
    case citrus, coastal, fog, desert, wetland, forest, meadow, hills

    fileprivate var palette: LandscapePalette {
        switch self {
        case .citrus: LandscapePalette(sky: (0xF3E3C8, 0xF6D9AE), sun: 0xFBE7C2, far: 0xB9A4B8, mid: 0x8C9B7A, near: 0x4F6B45, accent: 0xE59A3A, water: nil)
        case .coastal: LandscapePalette(sky: (0xDCE9EE, 0xF2EBDD), sun: 0xFFF6E2, far: 0xA9BCC7, mid: 0x9AA889, near: 0xB79C76, accent: 0xF2E6A6, water: 0x5E8FA6)
        case .fog: LandscapePalette(sky: (0xDDE3E3, 0xEEF0EC), sun: 0xF7F7F2, far: 0xB8C4C6, mid: 0x93A6A8, near: 0x5D7472, accent: 0xFFFFFF, water: nil)
        case .desert: LandscapePalette(sky: (0xF2DCC6, 0xF5E6CF), sun: 0xFBEAD0, far: 0xC9A08A, mid: 0xD6B48C, near: 0xB98A62, accent: 0x6F7F55, water: nil)
        case .wetland: LandscapePalette(sky: (0xE2EBE6, 0xF1EEDF), sun: 0xFBF3DD, far: 0xA8B9B0, mid: 0x7F9A7C, near: 0x5C7A55, accent: 0x8A7A52, water: 0x7FA3A8)
        case .forest: LandscapePalette(sky: (0xE3ECE8, 0xF2EEE0), sun: 0xFBF4DF, far: 0xA7B8B6, mid: 0x6F8C7A, near: 0x3F5E4C, accent: 0x2F4A3D, water: nil)
        case .meadow: LandscapePalette(sky: (0xE4EDF0, 0xF3EFDF), sun: 0xFFF5DA, far: 0xB3C2C4, mid: 0x9DB27E, near: 0x6E8F55, accent: 0xEDE3F2, water: nil)
        case .hills: LandscapePalette(sky: (0xE6E5EE, 0xF4ECDD), sun: 0xFCEBD2, far: 0xB4AFC4, mid: 0x9A9F8C, near: 0x667A5E, accent: 0xD8C7A0, water: nil)
        }
    }
}

private struct LandscapePalette {
    let sky: (UInt32, UInt32)
    let sun: UInt32
    let far: UInt32
    let mid: UInt32
    let near: UInt32
    let accent: UInt32
    let water: UInt32?
}

private extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

/// A small deterministic generator, so a landscape draws the same every time for the same seed.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// FNV-1a over the string's UTF-8: stable across launches, unlike `hashValue`.
    static func seed(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}

/// The drawing: fills whatever frame it is given (a wide Atlas band or a Guild card's header).
struct LandscapeArt: View {
    let landscape: Landscape
    var seed: UInt64 = 0

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            draw(in: &context, size: size)
        }
        .accessibilityHidden(true)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        var random = SeededRandom(seed: seed ^ SeededRandom.seed(landscape.rawValue))
        let palette = landscape.palette
        let w = size.width, h = size.height
        let rect = CGRect(origin: .zero, size: size)

        // The sky, and a soft sun low over the far ridge.
        context.fill(Path(rect), with: .linearGradient(
            Gradient(colors: [Color(hex: palette.sky.0), Color(hex: palette.sky.1)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: h)
        ))
        let sunX = w * Double.random(in: 0.58...0.82, using: &random)
        let sunR = h * 0.2
        context.fill(
            Path(ellipseIn: CGRect(x: sunX - sunR * 2.2, y: h * 0.32 - sunR * 2.2, width: sunR * 4.4, height: sunR * 4.4)),
            with: .radialGradient(Gradient(colors: [Color(hex: palette.sun, opacity: 0.9), Color(hex: palette.sun, opacity: 0)]),
                                  center: CGPoint(x: sunX, y: h * 0.32), startRadius: sunR * 0.6, endRadius: sunR * 2.2)
        )
        context.fill(Path(ellipseIn: CGRect(x: sunX - sunR / 2, y: h * 0.32 - sunR / 2, width: sunR, height: sunR)),
                     with: .color(Color(hex: palette.sun)))

        switch landscape {
        case .fog:
            for (index, level) in [0.42, 0.52, 0.63, 0.76].enumerated() {
                let tone = [palette.far, palette.far, palette.mid, palette.near][index]
                context.fill(ridge(w: w, h: h, base: h * level, amplitude: h * 0.09, random: &random),
                             with: .color(Color(hex: tone, opacity: 0.55 + 0.12 * Double(index))))
                context.fill(Path(CGRect(x: 0, y: h * (level + 0.03), width: w, height: h * 0.1)),
                             with: .linearGradient(Gradient(colors: [Color(hex: palette.accent, opacity: 0), Color(hex: palette.accent, opacity: 0.55), Color(hex: palette.accent, opacity: 0)]),
                                                   startPoint: CGPoint(x: 0, y: h * (level + 0.03)), endPoint: CGPoint(x: 0, y: h * (level + 0.13))))
            }
        case .desert:
            context.fill(ridge(w: w, h: h, base: h * 0.5, amplitude: h * 0.12, random: &random, sharp: true), with: .color(Color(hex: palette.far, opacity: 0.8)))
            context.fill(ridge(w: w, h: h, base: h * 0.66, amplitude: h * 0.06, random: &random, waves: 1.2), with: .color(Color(hex: palette.mid)))
            context.fill(ridge(w: w, h: h, base: h * 0.82, amplitude: h * 0.05, random: &random, waves: 0.8), with: .color(Color(hex: palette.near)))
            for _ in 0..<3 {
                cactus(in: &context, x: w * Double.random(in: 0.08...0.92, using: &random), base: h * Double.random(in: 0.8...0.92, using: &random), height: h * 0.16, color: Color(hex: palette.accent))
            }
        default:
            context.fill(ridge(w: w, h: h, base: h * 0.5, amplitude: h * 0.14, random: &random, sharp: landscape == .hills || landscape == .citrus),
                         with: .color(Color(hex: palette.far, opacity: 0.85)))
            if let water = palette.water {
                let top = h * (landscape == .coastal ? 0.58 : 0.66)
                context.fill(Path(CGRect(x: 0, y: top, width: w, height: h - top)),
                             with: .linearGradient(Gradient(colors: [Color(hex: water, opacity: 0.85), Color(hex: water)]), startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: h)))
                for _ in 0..<9 {
                    let y = Double.random(in: top + 4...h - 6, using: &random)
                    let x = Double.random(in: 0...w * 0.85, using: &random)
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: y))
                    line.addLine(to: CGPoint(x: x + w * Double.random(in: 0.05...0.14, using: &random), y: y))
                    context.stroke(line, with: .color(.white.opacity(0.45)), lineWidth: 1.2)
                }
                if landscape == .coastal {
                    // A headland down one side.
                    var cliff = Path()
                    let left = Bool.random(using: &random)
                    let edge = left ? 0.0 : w
                    let reach = w * 0.34 * (left ? 1 : -1)
                    cliff.move(to: CGPoint(x: edge, y: h * 0.52))
                    cliff.addCurve(to: CGPoint(x: edge + reach, y: h * 0.74), control1: CGPoint(x: edge + reach * 0.5, y: h * 0.5), control2: CGPoint(x: edge + reach * 0.9, y: h * 0.6))
                    cliff.addLine(to: CGPoint(x: edge + reach * 0.85, y: h))
                    cliff.addLine(to: CGPoint(x: edge, y: h))
                    cliff.closeSubpath()
                    context.fill(cliff, with: .color(Color(hex: palette.near)))
                    var grass = Path()
                    grass.move(to: CGPoint(x: edge, y: h * 0.52))
                    grass.addCurve(to: CGPoint(x: edge + reach, y: h * 0.74), control1: CGPoint(x: edge + reach * 0.5, y: h * 0.5), control2: CGPoint(x: edge + reach * 0.9, y: h * 0.6))
                    context.stroke(grass, with: .color(Color(hex: palette.mid)), lineWidth: h * 0.05)
                    for _ in 0..<14 {
                        let t = Double.random(in: 0.05...0.8, using: &random)
                        context.fill(Path(ellipseIn: CGRect(x: edge + reach * t, y: h * (0.53 + 0.2 * t * t) - 3, width: 3.5, height: 3.5)), with: .color(Color(hex: palette.accent)))
                    }
                } else {
                    context.fill(ridge(w: w, h: h, base: h * 0.64, amplitude: h * 0.03, random: &random), with: .color(Color(hex: palette.mid)))
                    reeds(in: &context, w: w, h: h, random: &random, color: Color(hex: palette.accent))
                }
            } else {
                context.fill(ridge(w: w, h: h, base: h * 0.64, amplitude: h * 0.08, random: &random), with: .color(Color(hex: palette.mid)))
                context.fill(ridge(w: w, h: h, base: h * 0.8, amplitude: h * 0.06, random: &random, waves: 1.4), with: .color(Color(hex: palette.near)))
                switch landscape {
                case .citrus: orchard(in: &context, w: w, h: h, random: &random, leaf: Color(hex: palette.near), fruit: Color(hex: palette.accent))
                case .forest: conifers(in: &context, w: w, h: h, random: &random, color: Color(hex: palette.accent))
                case .meadow, .hills: flowers(in: &context, w: w, h: h, random: &random, color: Color(hex: palette.accent))
                default: break
                }
            }
        }

        // A few distant birds, very small: the set's life, never a particular species.
        for _ in 0..<3 {
            let x = w * Double.random(in: 0.15...0.85, using: &random)
            let y = h * Double.random(in: 0.12...0.3, using: &random)
            let span = max(5, h * 0.035)
            var bird = Path()
            bird.move(to: CGPoint(x: x - span, y: y - span * 0.3))
            bird.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: x - span * 0.5, y: y - span * 0.6))
            bird.addQuadCurve(to: CGPoint(x: x + span, y: y - span * 0.3), control: CGPoint(x: x + span * 0.5, y: y - span * 0.6))
            context.stroke(bird, with: .color(Color(hex: 0x3A4A4A, opacity: 0.55)), lineWidth: 1.2)
        }
    }

    private func ridge(w: Double, h: Double, base: Double, amplitude: Double, random: inout SeededRandom, waves: Double = 2.2, sharp: Bool = false) -> Path {
        let phase1 = Double.random(in: 0...(2 * .pi), using: &random)
        let phase2 = Double.random(in: 0...(2 * .pi), using: &random)
        let freq2 = Double.random(in: 2.5...4.5, using: &random)
        var path = Path()
        path.move(to: CGPoint(x: 0, y: h))
        let steps = 48
        for step in 0...steps {
            let t = Double(step) / Double(steps)
            var y = sin(t * waves * .pi + phase1) * 0.65 + sin(t * freq2 * .pi + phase2) * 0.35
            if sharp { y = -abs(y) * 1.3 + 0.4 }
            path.addLine(to: CGPoint(x: t * w, y: base - y * amplitude))
        }
        path.addLine(to: CGPoint(x: w, y: h))
        path.closeSubpath()
        return path
    }

    private func orchard(in context: inout GraphicsContext, w: Double, h: Double, random: inout SeededRandom, leaf: Color, fruit: Color) {
        let rows = [(0.74, 0.07), (0.86, 0.1), (0.98, 0.13)]
        for (y, size) in rows {
            var x = Double.random(in: -10...10, using: &random)
            while x < w + 20 {
                let r = h * size * Double.random(in: 0.8...1.15, using: &random)
                let cy = h * y
                context.fill(Path(ellipseIn: CGRect(x: x - r, y: cy - r * 0.9, width: r * 2, height: r * 1.7)), with: .color(leaf))
                context.fill(Path(ellipseIn: CGRect(x: x - r * 0.6, y: cy - r * 1.05, width: r * 1.1, height: r * 0.9)), with: .color(leaf.opacity(0.75)))
                for _ in 0..<5 {
                    let fx = x + Double.random(in: -r * 0.7...r * 0.7, using: &random)
                    let fy = cy + Double.random(in: -r * 0.7...r * 0.5, using: &random)
                    let fr = max(2, r * 0.13)
                    context.fill(Path(ellipseIn: CGRect(x: fx, y: fy, width: fr, height: fr)), with: .color(fruit))
                }
                x += r * Double.random(in: 1.6...2.2, using: &random)
            }
        }
    }

    private func conifers(in context: inout GraphicsContext, w: Double, h: Double, random: inout SeededRandom, color: Color) {
        for row in 0..<2 {
            var x = Double.random(in: 0...16, using: &random)
            let base = h * (row == 0 ? 0.7 : 0.9)
            while x < w {
                let height = h * (row == 0 ? 0.2 : 0.32) * Double.random(in: 0.75...1.2, using: &random)
                let half = height * 0.22
                var tree = Path()
                tree.move(to: CGPoint(x: x, y: base - height))
                tree.addLine(to: CGPoint(x: x + half, y: base))
                tree.addLine(to: CGPoint(x: x - half, y: base))
                tree.closeSubpath()
                context.fill(tree, with: .color(color.opacity(row == 0 ? 0.7 : 1)))
                x += half * Double.random(in: 1.4...3.2, using: &random)
            }
        }
    }

    private func reeds(in context: inout GraphicsContext, w: Double, h: Double, random: inout SeededRandom, color: Color) {
        for _ in 0..<40 {
            let x = Double.random(in: 0...w, using: &random)
            guard x < w * 0.3 || x > w * 0.7 else { continue }
            let height = h * Double.random(in: 0.12...0.3, using: &random)
            var reed = Path()
            reed.move(to: CGPoint(x: x, y: h))
            reed.addQuadCurve(to: CGPoint(x: x + Double.random(in: -6...6, using: &random), y: h - height), control: CGPoint(x: x, y: h - height * 0.5))
            context.stroke(reed, with: .color(color), lineWidth: 1.4)
            if Bool.random(using: &random) {
                context.fill(Path(roundedRect: CGRect(x: x - 1.8, y: h - height, width: 3.6, height: height * 0.22), cornerRadius: 1.8), with: .color(color.opacity(0.9)))
            }
        }
    }

    private func flowers(in context: inout GraphicsContext, w: Double, h: Double, random: inout SeededRandom, color: Color) {
        for _ in 0..<36 {
            let x = Double.random(in: 0...w, using: &random)
            let y = h * Double.random(in: 0.84...0.99, using: &random)
            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 3, height: 3)), with: .color(color))
        }
    }

    private func cactus(in context: inout GraphicsContext, x: Double, base: Double, height: Double, color: Color) {
        let width = max(3, height * 0.14)
        context.fill(Path(roundedRect: CGRect(x: x - width / 2, y: base - height, width: width, height: height), cornerRadius: width / 2), with: .color(color))
        context.fill(Path(roundedRect: CGRect(x: x - width * 2, y: base - height * 0.7, width: width * 0.8, height: height * 0.35), cornerRadius: width / 2), with: .color(color))
        context.fill(Path(roundedRect: CGRect(x: x - width * 2, y: base - height * 0.4, width: width * 1.8, height: width * 0.8), cornerRadius: width / 2), with: .color(color))
    }
}

/// A set's cover for the Atlas (issue #118 over #114's `PackLibrary.cover(setID:)`): the bundled cover, else the pack's, else
/// the index's thumbnail. Scaled to fill the frame it is given and cropped from the middle, as the covers were painted to be.
/// All five sets ship their covers (issue #150), so a set the app has no cover for, which none is today, shows the raised
/// surface rather than a drawn landscape.
struct SetCoverImage: View {
    @Environment(PackLibrary.self) private var library
    let setID: String
    @State private var image: UIImage?

    var body: some View {
        let cover = library.cover(setID: setID)
        Color.raised
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .allowsHitTesting(false)  // a clipped picture still takes touches outside its clip
                }
            }
            .clipped()
            .accessibilityHidden(true)
            .task(id: cover) {
                image = await Self.load(cover)
            }
    }

    /// Decodes the cover off the main actor.
    static func load(_ cover: SetCover?) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { decoded(cover) }.value
    }

    /// The cover's pixels, decoded now rather than at its first draw: a JPEG in the app, an AVIF in a pack, or the index's JPEG.
    nonisolated static func decoded(_ cover: SetCover?) -> UIImage? {
        switch cover {
        case let .bundled(_, url), let .pack(_, url):
            UIImage(contentsOfFile: url.path(percentEncoded: false))?.preparingForDisplay()
        case let .thumbnail(thumbnail):
            UIImage(data: thumbnail.thumbnail)?.preparingForDisplay()
        case nil:
            nil
        }
    }
}
