import SwiftUI

/// What an edition's patch looks like when the app draws it: its silhouette, its cord and its twill (guide page 11, the
/// same values as `art/patch-prompts.json`). It's the shape of the blank when there's no painting on the phone, and the
/// shape every painting of the edition is fitted to, so a board reads as a set (guide page 9, "One footprint per edition").
struct PatchEdition: Equatable {
    enum Shape: Equatable {
        case circle, oval, hexagon, arch, shield, pentagon, roundedSquare, diamond

        /// How far down a blank the slot for its paper tag is cut, as a part of the patch's height: lower under a point,
        /// so the tag hangs where the cloth is as wide as it is.
        var tagDrop: CGFloat {
            switch self {
            case .pentagon: 0.16
            case .diamond: 0.24
            case .circle, .oval, .hexagon, .arch, .shield, .roundedSquare: 0.1
            }
        }
    }

    let shape: Shape
    let cord: Color
    let twill: Color

    /// Width over height.
    var aspect: CGFloat {
        switch shape {
        case .circle: 1
        case .oval: 0.78
        case .hexagon: 1.12
        case .arch: 0.86
        case .shield: 0.84
        // A regular pentagon on its flat: 2 sin 72° wide to 1 + cos 36° tall.
        case .pentagon: 1.05
        case .roundedSquare, .diamond: 1
        }
    }

    /// The plain natural canvas of Uncharted (guide page 15), which has a weave rather than a twill's rib.
    var isCanvas: Bool { self == .of(setID: nil) }

    /// The edition of a set by its pack id; Uncharted (nil) and any set without its own is the plain canvas round.
    static func of(setID: String?) -> PatchEdition {
        switch setID {
        case "us-ca-la": PatchEdition(shape: .circle, cord: Color(hex: 0x6E7A3A), twill: Color(hex: 0xC4A068))
        case "us-ca-sd": PatchEdition(shape: .oval, cord: Color(hex: 0x1F4E79), twill: Color(hex: 0xCFE0EA))
        case "us-ca-bay": PatchEdition(shape: .hexagon, cord: Color(hex: 0x9AA3A8), twill: Color(hex: 0xDADDDD))
        case "us-ca-desert": PatchEdition(shape: .arch, cord: Color(hex: 0xB5654F), twill: Color(hex: 0xE4CDA8))
        case "us-fl-orlando": PatchEdition(shape: .shield, cord: Color(hex: 0x1C6B6B), twill: Color(hex: 0xF2EFE6))
        case "us-pnw": PatchEdition(shape: .pentagon, cord: Color(hex: 0x34503F), twill: Color(hex: 0xB4BEC8))
        case "us-ny-nyc": PatchEdition(shape: .roundedSquare, cord: Color(hex: 0x9B2F27), twill: Color(hex: 0xF0E0C6))
        case "us-la-south": PatchEdition(shape: .diamond, cord: Color(hex: 0x5A2A4E), twill: Color(hex: 0xE9D3AC))
        default: PatchEdition(shape: .circle, cord: Color(hex: 0x6E4B2E), twill: Color(hex: 0xD8CBB0))
        }
    }
}

extension PatchEdition {
    /// The thread of an edition by its set's pack id: the accent where the birder is, and on a set's or a patch's own page
    /// (issue #150). Uncharted (nil) has its own; a set the app doesn't know keeps today's aqua. A colorset for each, with its
    /// Increase Contrast variants; `EditionTintTests` measures them. Unlike the cord and twill, these follow the appearance.
    static func tint(setID: String?) -> Color {
        switch setID {
        case "us-ca-la": Color("EditionCitrus")
        case "us-ca-sd": Color("EditionCoastal")
        case "us-ca-bay": Color("EditionFog")
        case "us-ca-desert": Color("EditionDesert")
        case "us-fl-orlando": Color("EditionWetland")
        case "us-pnw": Color("EditionEvergreen")
        case "us-ny-nyc": Color("EditionBorough")
        case "us-la-south": Color("EditionBayou")
        case nil: Color("EditionUncharted")
        default: .moss
        }
    }
}

extension PatchEdition {
    /// An edition's thread printed on a plate's paper, the issue's values and the mock's, for Citrus: the light tints were deepened from
    /// these for words on linen, and a stitch on paper needs 3:1, not 4.5 (`plateStock`). Increase Contrast takes the deeper tint.
    static func paperThread(setID: String?) -> Color {
        switch setID {
        case "us-ca-la": Color(hex: 0x5C6420)
        case "us-ca-sd": Color(hex: 0x1E5F86)
        case "us-ca-bay": Color(hex: 0x4F5F66)
        case "us-ca-desert": Color(hex: 0x9A4A2F)
        case "us-fl-orlando": Color(hex: 0x0F6B60)
        case "us-pnw": Color(hex: 0x2D6043)
        case "us-ny-nyc": Color(hex: 0x9E2F28)
        case "us-la-south": Color(hex: 0x833E71)
        default: tint(setID: setID)
        }
    }
}

extension Color {
    /// A colour from its fixed sRGB value: for the materials and the editions, which don't change with the appearance.
    init(hex: UInt32) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    /// "#C4A068"; nil for anything else.
    init?(hexString: String) {
        guard hexString.hasPrefix("#"), hexString.count == 7, let value = UInt32(hexString.dropFirst(), radix: 16) else { return nil }
        self.init(hex: value)
    }
}

/// An edition's silhouette in a rectangle of its aspect.
nonisolated struct PatchOutline: Shape {
    let shape: PatchEdition.Shape

    func path(in rect: CGRect) -> Path {
        switch shape {
        case .circle, .oval:
            return Path(ellipseIn: rect)
        case .hexagon:
            let inset = rect.width * 0.25
            var path = Path()
            path.move(to: CGPoint(x: rect.minX + inset, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + inset, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.closeSubpath()
            return path
        case .arch:
            let radius = rect.width / 2
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
            path.addArc(center: CGPoint(x: rect.midX, y: rect.minY + radius), radius: radius, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.closeSubpath()
            return path
        case .shield:
            var path = Path()
            let shoulder = rect.height * 0.14
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + shoulder), control: CGPoint(x: rect.maxX - rect.width * 0.2, y: rect.minY + shoulder))
            path.addCurve(to: CGPoint(x: rect.midX, y: rect.maxY), control1: CGPoint(x: rect.maxX, y: rect.midY + rect.height * 0.14), control2: CGPoint(x: rect.midX + rect.width * 0.26, y: rect.maxY - rect.height * 0.1))
            path.addCurve(to: CGPoint(x: rect.minX, y: rect.minY + shoulder), control1: CGPoint(x: rect.midX - rect.width * 0.26, y: rect.maxY - rect.height * 0.1), control2: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.14))
            path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.minY), control: CGPoint(x: rect.minX + rect.width * 0.2, y: rect.minY + shoulder))
            path.closeSubpath()
            return path
        case .pentagon:
            // `art/patch-prompts.json`'s outline: a point at the top, the flat along the bottom.
            let corners: [(x: CGFloat, y: CGFloat)] = [(0.5, 0), (1, 0.382), (0.809, 1), (0.191, 1), (0, 0.382)]
            var path = Path()
            path.addLines(corners.map { CGPoint(x: rect.minX + rect.width * $0.x, y: rect.minY + rect.height * $0.y) })
            path.closeSubpath()
            return path
        case .roundedSquare:
            return Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) * 0.18)
        case .diamond:
            // A square on its corner. Its points are rounded, and it's drawn a little past the rectangle so the rounded
            // points touch the rectangle's sides, as a painting's do the edges of its picture.
            let radius = min(rect.width, rect.height) * 0.06
            let past = radius * (2.squareRoot() - 1)
            let (top, right) = (CGPoint(x: rect.midX, y: rect.minY - past), CGPoint(x: rect.maxX + past, y: rect.midY))
            let (bottom, left) = (CGPoint(x: rect.midX, y: rect.maxY + past), CGPoint(x: rect.minX - past, y: rect.midY))
            var path = Path()
            path.move(to: CGPoint(x: (top.x + right.x) / 2, y: (top.y + right.y) / 2))
            path.addArc(tangent1End: right, tangent2End: bottom, radius: radius)
            path.addArc(tangent1End: bottom, tangent2End: left, radius: radius)
            path.addArc(tangent1End: left, tangent2End: top, radius: radius)
            path.addArc(tangent1End: top, tangent2End: right, radius: radius)
            path.closeSubpath()
            return path
        }
    }
}
