import SwiftUI

/// What an edition's patch looks like when the app draws it: its silhouette, its cord and its twill (guide page 11, the
/// same values as `art/patch-prompts.json`). It's the shape of the blank when there's no painting on the phone, and the
/// shape every painting of the edition is fitted to, so a board reads as a set (guide page 9, "One footprint per edition").
struct PatchEdition: Equatable {
    enum Shape: Equatable {
        case circle, oval, hexagon, arch, shield
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
        }
    }

    /// The edition of a set by its pack id; Uncharted (nil) and any set without its own is the plain canvas round.
    static func of(setID: String?) -> PatchEdition {
        switch setID {
        case "us-ca-la": PatchEdition(shape: .circle, cord: Color(hex: 0x6E7A3A), twill: Color(hex: 0xC4A068))
        case "us-ca-sd": PatchEdition(shape: .oval, cord: Color(hex: 0x1F4E79), twill: Color(hex: 0xCFE0EA))
        case "us-ca-bay": PatchEdition(shape: .hexagon, cord: Color(hex: 0x9AA3A8), twill: Color(hex: 0xDADDDD))
        case "us-ca-desert": PatchEdition(shape: .arch, cord: Color(hex: 0xB5654F), twill: Color(hex: 0xE4CDA8))
        case "us-fl-orlando": PatchEdition(shape: .shield, cord: Color(hex: 0x1C6B6B), twill: Color(hex: 0xF2EFE6))
        default: PatchEdition(shape: .circle, cord: Color(hex: 0x6E4B2E), twill: Color(hex: 0xD8CBB0))
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
        }
    }
}
