import SwiftUI
import Testing
import UIKit
@testable import BirdJournal

// Issue #119, design guide page 16: every token pairing the app draws, in light, dark and each with Increase Contrast,
// at 4.5:1 for text and 3:1 for glyphs and marks; and the text on the translucent surfaces (the toast's regular
// material, the bar material under Stop and the review sheet's actions), measured on the rendered pixels over the page,
// a raised surface and the card face. #116's `DesignTokenTests` keeps the guide's values and the card face's pairings.
@Suite("Token pairings")
@MainActor
struct TokenPairingTests {
    typealias Variant = (name: String, traits: UITraitCollection)

    /// Every text colour on every surface it sits on in the app (where the views put them), at 4.5:1.
    static let textPairings: [(text: String, surface: String)] = [
        // The page and the raised surface carry every text token.
        ("JournalInk", "JournalPaper"), ("JournalInk", "JournalRaised"),
        ("JournalInkSecondary", "JournalPaper"), ("JournalInkSecondary", "JournalRaised"),
        ("JournalMoss", "JournalPaper"), ("JournalMoss", "JournalRaised"),
        ("AccentColor", "JournalPaper"), ("AccentColor", "JournalRaised"),
        ("JournalAlert", "JournalPaper"), ("JournalAlert", "JournalRaised"),
        // A primary action's label.
        ("JournalMossText", "JournalMoss"),
        // Shared goals: everything on the lavender is `onSharedGoal`.
        ("JournalOnSharedGoal", "JournalSharedGoal"),
    ]

    /// Glyphs and marks at 3:1: the connection dot and progress fills (moss), the listening status ring (ink, secondary
    /// ink), the goal bar on the lavender, the error mark.
    static let glyphPairings: [(glyph: String, surface: String)] = [
        ("JournalMoss", "JournalPaper"), ("JournalMoss", "JournalRaised"),
        ("JournalInk", "JournalPaper"), ("JournalInkSecondary", "JournalPaper"), ("JournalInkSecondary", "JournalRaised"),
        ("JournalOnSharedGoal", "JournalSharedGoal"),
        ("JournalAlert", "JournalPaper"), ("JournalAlert", "JournalRaised"),
    ]

    @Test("every text pairing is at least 4.5:1 in all four variants")
    func text() throws {
        for pairing in Self.textPairings {
            try expect(pairing.text, on: pairing.surface, atLeast: 4.5)
        }
    }

    @Test("every glyph and mark is at least 3:1 in all four variants")
    func glyphs() throws {
        for pairing in Self.glyphPairings {
            try expect(pairing.glyph, on: pairing.surface, atLeast: 3)
        }
    }

    @Test("the alert token replaces the system red, which missed 4.5:1 on the page")
    func alertBeatsSystemRed() throws {
        for variant in DesignTokenTests.variants where !variant.name.contains("Increase") {
            let paper = try DesignTokenTests.color("JournalPaper", variant.traits)
            let raised = try DesignTokenTests.color("JournalRaised", variant.traits)
            let red = UIColor.systemRed.resolvedColor(with: variant.traits)
            #expect(min(DesignTokenTests.contrast(red, paper), DesignTokenTests.contrast(red, raised)) < 4.5, "the system red would do in \(variant.name)")
            let alert = try DesignTokenTests.color("JournalAlert", variant.traits)
            #expect(DesignTokenTests.contrast(alert, raised) >= 5.5, "\(variant.name)")
        }
    }

    // MARK: - Translucent surfaces

    enum Surface: String, CaseIterable {
        /// The toast ("Added to your collection").
        case regularMaterial
        /// Stop listening's bar and the review sheet's actions.
        case bar

        var style: AnyShapeStyle {
            switch self {
            case .regularMaterial: AnyShapeStyle(.regularMaterial)
            case .bar: AnyShapeStyle(.bar)
            }
        }
    }

    @Test("text on the materials, over the page, a raised surface and the card face, is at least 4.5:1", arguments: Surface.allCases)
    func materials(_ surface: Surface) async throws {
        for variant in DesignTokenTests.variants {
            for behind in ["JournalPaper", "JournalRaised", "CollectibleFace"] {
                let backdrop = try DesignTokenTests.color(behind, variant.traits)
                let rendered = try await Self.render(surface, over: Color(behind), traits: variant.traits)
                #expect(rendered != nil, "nothing rendered for \(surface) over \(behind), \(variant.name)")
                guard let rendered else { continue }
                // The material is drawn: the pixel is not just the backdrop (else the measure proves nothing).
                #expect(Self.distance(rendered, backdrop) > 0.01 || behind == "CollectibleFace", "\(surface) over \(behind), \(variant.name) drew no material")
                for text in ["JournalInk", "JournalMoss"] {
                    let ratio = DesignTokenTests.contrast(try DesignTokenTests.color(text, variant.traits), rendered)
                    #expect(ratio >= 4.5, "\(text) on \(surface) over \(behind) (\(Self.hex(rendered))), \(variant.name): \(String(format: "%.2f", ratio)):1")
                }
            }
        }
    }

    /// The centre pixel of `surface` drawn over `backdrop` in a window with `traits`' appearance and contrast.
    static func render(_ surface: Surface, over backdrop: Color, traits: UITraitCollection) async throws -> UIColor? {
        let host = UIHostingController(rootView: ZStack {
            backdrop
            Rectangle().fill(surface.style)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, traits.userInterfaceStyle == .dark ? .dark : .light))
        host.overrideUserInterfaceStyle = traits.userInterfaceStyle
        host.traitOverrides.accessibilityContrast = traits.accessibilityContrast
        // A window in the test host's scene, so it is drawn (a window outside any scene renders black).
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 120, height: 120)
        window.windowLevel = .alert + 1
        window.overrideUserInterfaceStyle = traits.userInterfaceStyle
        window.traitOverrides.accessibilityContrast = traits.accessibilityContrast
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.preferredRange = .standard
            return format
        }()).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        return pixel(image, at: CGPoint(x: 60, y: 60))
    }

    static func pixel(_ image: UIImage, at point: CGPoint) -> UIColor? {
        guard let cgImage = image.cgImage else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cgImage, in: CGRect(x: -point.x, y: -(CGFloat(cgImage.height) - point.y - 1), width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
        return UIColor(red: CGFloat(bytes[0]) / 255, green: CGFloat(bytes[1]) / 255, blue: CGFloat(bytes[2]) / 255, alpha: 1)
    }

    static func hex(_ color: UIColor) -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    static func distance(_ a: UIColor, _ b: UIColor) -> CGFloat {
        var (r1, g1, b1, a1, r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0, 0, 0, 0, 0)
        a.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        b.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return abs(r1 - r2) + abs(g1 - g2) + abs(b1 - b2)
    }

    func expect(_ foreground: String, on background: String, atLeast minimum: Double) throws {
        for variant in DesignTokenTests.variants {
            let ratio = DesignTokenTests.contrast(try DesignTokenTests.color(foreground, variant.traits), try DesignTokenTests.color(background, variant.traits))
            #expect(ratio >= minimum, "\(foreground) on \(background), \(variant.name): \(String(format: "%.2f", ratio)):1")
        }
    }
}
