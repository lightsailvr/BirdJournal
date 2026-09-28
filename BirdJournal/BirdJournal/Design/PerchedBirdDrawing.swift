import SwiftUI

/// A pencil-sketch bird perched on a leafy branch: warmth for the empty page, never in the way of the action.
/// Drawn in a 200 × 120 design space and scaled to fit; the bird in the ink colour with a faint wash and hatching,
/// the branch in the secondary colour. The postcard passes its own fixed palette so the export ignores the appearance.
struct PerchedBirdDrawing: View {
    var ink: Color = .ink
    var secondary: Color = .inkSecondary

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / 200, size.height / 120)
            let origin = CGPoint(x: (size.width - 200 * scale) / 2, y: (size.height - 120 * scale) / 2)
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * scale, y: origin.y + y * scale) }
            func stroke(width: CGFloat, opacity: Double, fill: Double? = nil, color: Color = ink, _ build: (inout Path) -> Void) {
                var p = Path()
                build(&p)
                if let fill { context.fill(p, with: .color(color.opacity(fill))) }
                context.stroke(p, with: .color(color.opacity(opacity)), style: StrokeStyle(lineWidth: width * scale, lineCap: .round, lineJoin: .round))
            }

            // branch
            stroke(width: 1.6, opacity: 0.75, color: secondary) { p in
                p.move(to: pt(4, 114))
                p.addCurve(to: pt(106, 90), control1: pt(40, 106), control2: pt(72, 98))
                p.addCurve(to: pt(196, 60), control1: pt(140, 82), control2: pt(160, 72))
            }
            // twig-left
            stroke(width: 1.0, opacity: 0.7, color: secondary) { p in
                p.move(to: pt(44, 105))
                p.addCurve(to: pt(36, 82), control1: pt(38, 98), control2: pt(34, 90))
            }
            // twig-right
            stroke(width: 1.0, opacity: 0.7, color: secondary) { p in
                p.move(to: pt(156, 74))
                p.addCurve(to: pt(160, 50), control1: pt(160, 66), control2: pt(162, 58))
            }
            // twig-far
            stroke(width: 0.9, opacity: 0.7, color: secondary) { p in
                p.move(to: pt(180, 65))
                p.addCurve(to: pt(196, 53), control1: pt(184, 59), control2: pt(189, 55))
            }
            // leaf
            stroke(width: 0.9, opacity: 0.7, color: secondary) { p in
                p.move(to: pt(36, 82))
                p.addCurve(to: pt(18, 84), control1: pt(30, 78), control2: pt(24, 79))
                p.addCurve(to: pt(36, 82), control1: pt(24, 87), control2: pt(31, 86))
                p.closeSubpath()
            }
            // rib
            stroke(width: 0.9, opacity: 0.6, color: secondary) { p in
                p.move(to: pt(36, 82))
                p.addLine(to: pt(18, 84))
            }
            // leaf
            stroke(width: 0.9, opacity: 0.7, color: secondary) { p in
                p.move(to: pt(40, 94))
                p.addCurve(to: pt(24, 102), control1: pt(34, 93), control2: pt(28, 96))
                p.addCurve(to: pt(40, 94), control1: pt(30, 102), control2: pt(36, 99))
                p.closeSubpath()
            }
            // rib
            stroke(width: 0.9, opacity: 0.6, color: secondary) { p in
                p.move(to: pt(40, 94))
                p.addLine(to: pt(24, 102))
            }
            // leaf
            stroke(width: 0.9, opacity: 0.7, color: secondary) { p in
                p.move(to: pt(160, 50))
                p.addCurve(to: pt(144, 48), control1: pt(155, 45), control2: pt(149, 45))
                p.addCurve(to: pt(160, 50), control1: pt(149, 53), control2: pt(156, 53))
                p.closeSubpath()
            }
            // rib
            stroke(width: 0.9, opacity: 0.6, color: secondary) { p in
                p.move(to: pt(160, 50))
                p.addLine(to: pt(144, 48))
            }
            // leaf
            stroke(width: 0.9, opacity: 0.7, color: secondary) { p in
                p.move(to: pt(162, 56))
                p.addCurve(to: pt(178, 55), control1: pt(167, 51), control2: pt(173, 51))
                p.addCurve(to: pt(162, 56), control1: pt(173, 60), control2: pt(166, 60))
                p.closeSubpath()
            }
            // rib
            stroke(width: 0.9, opacity: 0.6, color: secondary) { p in
                p.move(to: pt(162, 56))
                p.addLine(to: pt(178, 55))
            }
            // leaf
            stroke(width: 0.9, opacity: 0.7, color: secondary) { p in
                p.move(to: pt(172, 80))
                p.addCurve(to: pt(187, 89), control1: pt(178, 80), control2: pt(184, 84))
                p.addCurve(to: pt(172, 80), control1: pt(181, 89), control2: pt(175, 86))
                p.closeSubpath()
            }
            // rib
            stroke(width: 0.9, opacity: 0.6, color: secondary) { p in
                p.move(to: pt(172, 80))
                p.addLine(to: pt(187, 89))
            }
            // leaf
            stroke(width: 0.9, opacity: 0.7, color: secondary) { p in
                p.move(to: pt(196, 53))
                p.addCurve(to: pt(181, 42), control1: pt(193, 46), control2: pt(188, 42))
                p.addCurve(to: pt(196, 53), control1: pt(183, 49), control2: pt(189, 53))
                p.closeSubpath()
            }
            // rib
            stroke(width: 0.9, opacity: 0.6, color: secondary) { p in
                p.move(to: pt(196, 53))
                p.addLine(to: pt(181, 42))
            }
            // body
            stroke(width: 1.5, opacity: 1, fill: 0.10) { p in
                p.move(to: pt(128, 18))
                p.addCurve(to: pt(140, 24), control1: pt(133, 18), control2: pt(138, 20))
                p.addLine(to: pt(154, 29))
                p.addLine(to: pt(139, 32))
                p.addCurve(to: pt(136, 38), control1: pt(138, 35), control2: pt(137, 37))
                p.addCurve(to: pt(126, 66), control1: pt(136, 48), control2: pt(132, 58))
                p.addCurve(to: pt(109, 85), control1: pt(120, 76), control2: pt(115, 82))
                p.addCurve(to: pt(99, 88), control1: pt(105, 87), control2: pt(102, 88))
                p.addCurve(to: pt(93, 84), control1: pt(96, 88), control2: pt(94, 86))
                p.addCurve(to: pt(104, 40), control1: pt(86, 64), control2: pt(93, 48))
                p.addCurve(to: pt(116, 24), control1: pt(108, 34), control2: pt(111, 27))
                p.addCurve(to: pt(128, 18), control1: pt(119, 20), control2: pt(123, 18))
                p.closeSubpath()
            }
            // eye
            context.fill(Path(ellipseIn: CGRect(x: pt(132, 26).x - 1.7 * scale, y: pt(132, 26).y - 1.7 * scale, width: 3.4 * scale, height: 3.4 * scale)), with: .color(ink))
            // gape
            stroke(width: 0.7, opacity: 0.55) { p in
                p.move(to: pt(139, 32))
                p.addCurve(to: pt(133, 32), control1: pt(137, 31), control2: pt(135, 31))
            }
            // wing
            stroke(width: 1.2, opacity: 1, fill: 0.12) { p in
                p.move(to: pt(112, 34))
                p.addCurve(to: pt(94, 70), control1: pt(102, 44), control2: pt(96, 58))
                p.addCurve(to: pt(92, 82), control1: pt(93, 76), control2: pt(92, 80))
                p.addCurve(to: pt(104, 58), control1: pt(98, 74), control2: pt(100, 66))
                p.addCurve(to: pt(112, 34), control1: pt(110, 48), control2: pt(114, 40))
                p.closeSubpath()
            }
            // hatch
            stroke(width: 0.8, opacity: 0.5) { p in
                p.move(to: pt(109, 42))
                p.addCurve(to: pt(95, 74), control1: pt(103, 52), control2: pt(98, 62))
            }
            // hatch
            stroke(width: 0.8, opacity: 0.5) { p in
                p.move(to: pt(106, 48))
                p.addCurve(to: pt(96, 78), control1: pt(101, 58), control2: pt(98, 66))
            }
            // hatch
            stroke(width: 0.8, opacity: 0.5) { p in
                p.move(to: pt(111, 50))
                p.addCurve(to: pt(98, 76), control1: pt(106, 58), control2: pt(101, 68))
            }
            // shade
            stroke(width: 0.7, opacity: 0.32) { p in
                p.move(to: pt(131, 54))
                p.addCurve(to: pt(120, 72), control1: pt(128, 60), control2: pt(124, 66))
            }
            // shade
            stroke(width: 0.7, opacity: 0.32) { p in
                p.move(to: pt(127, 50))
                p.addCurve(to: pt(116, 68), control1: pt(124, 56), control2: pt(120, 62))
            }
            // shade
            stroke(width: 0.7, opacity: 0.32) { p in
                p.move(to: pt(123, 75))
                p.addCurve(to: pt(111, 84), control1: pt(119, 79), control2: pt(115, 82))
            }
            // tail
            stroke(width: 1.3, opacity: 1) { p in
                p.move(to: pt(93, 82))
                p.addCurve(to: pt(62, 108), control1: pt(84, 90), control2: pt(72, 100))
                p.addLine(to: pt(68, 112))
                p.addCurve(to: pt(99, 88), control1: pt(78, 102), control2: pt(90, 94))
            }
            // tail-line
            stroke(width: 0.8, opacity: 0.5) { p in
                p.move(to: pt(88, 88))
                p.addLine(to: pt(67, 106))
            }
            // legs
            stroke(width: 1.1, opacity: 1) { p in
                p.move(to: pt(111, 84))
                p.addLine(to: pt(115, 88.5))
                p.move(to: pt(115, 88.5))
                p.addLine(to: pt(120, 87.5))
                p.move(to: pt(115, 88.5))
                p.addLine(to: pt(113.5, 92))
                p.move(to: pt(105, 86.5))
                p.addLine(to: pt(108, 90))
                p.move(to: pt(108, 90))
                p.addLine(to: pt(113, 89.5))
                p.move(to: pt(108, 90))
                p.addLine(to: pt(106.5, 93.5))
            }
        }
    }
}

#Preview("Perched bird") {
    VStack(spacing: 30) {
        PerchedBirdDrawing().frame(height: 118)
        PerchedBirdDrawing().frame(height: 90)
    }
    .padding()
    .background(Color.paper)
}
