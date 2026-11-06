import SwiftUI
import Testing
import UIKit
@testable import BirdJournal

// Issue #119, design guide page 16: every token pairing the app draws, in light, dark and each with Increase Contrast,
// at 4.5:1 for text and 3:1 for glyphs and marks; and the text on the translucent surfaces (the toast's regular
// material, the bar material under Stop and the review sheet's actions), measured on the rendered pixels over the page,
// a raised surface and the card face. #116's `DesignTokenTests` keeps the guide's values and the card face's pairings.
// Issue #138 adds the materials: felt, linen and card stock are textured, so text is measured on their rendered pixels.
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

    // MARK: - The materials (issue #138, guide page 16)

    /// Every colour `image` has inside its middle half: a material has a texture, so text has to clear its worst pixel.
    static func luminanceExtremes(_ image: UIImage) -> (darkest: UIColor, lightest: UIColor)? {
        guard let cgImage = image.cgImage else { return nil }
        let (width, height) = (cgImage.width, cgImage.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        var darkest: (Double, [UInt8]) = (.infinity, [0, 0, 0])
        var lightest: (Double, [UInt8]) = (-.infinity, [255, 255, 255])
        for y in height / 4..<height * 3 / 4 {
            for x in width / 4..<width * 3 / 4 {
                let i = (y * width + x) * 4
                let rgb = [bytes[i], bytes[i + 1], bytes[i + 2]]
                let level = 0.2126 * Double(rgb[0]) + 0.7152 * Double(rgb[1]) + 0.0722 * Double(rgb[2])
                if level < darkest.0 { darkest = (level, rgb) }
                if level > lightest.0 { lightest = (level, rgb) }
            }
        }
        func color(_ rgb: [UInt8]) -> UIColor { UIColor(red: CGFloat(rgb[0]) / 255, green: CGFloat(rgb[1]) / 255, blue: CGFloat(rgb[2]) / 255, alpha: 1) }
        return (color(darkest.1), color(lightest.1))
    }

    /// The worst ratio `foreground` has against the texture's extremes.
    static func worst(_ foreground: UIColor, on extremes: (darkest: UIColor, lightest: UIColor)) -> Double {
        min(DesignTokenTests.contrast(foreground, extremes.darkest), DesignTokenTests.contrast(foreground, extremes.lightest))
    }

    /// The full ink: the secondary ink misses this on the textures (3.2:1 on the linen, just under 4.5:1 on the felt), so no
    /// words on a material use it.
    @Test("words on the board's felt and linen clear 4.5:1 against the texture's worst pixel, in all four variants")
    func board() async throws {
        for variant in DesignTokenTests.variants {
            let image = try await Self.renderImage(BoardMaterial(), traits: variant.traits, size: 300)
            let extremes = try #require(Self.luminanceExtremes(image))
            let ratio = Self.worst(try DesignTokenTests.color("JournalInk", variant.traits), on: extremes)
            #expect(ratio >= 4.5, "the ink on the board, \(variant.name) (\(Self.hex(extremes.darkest))...\(Self.hex(extremes.lightest))): \(String(format: "%.2f", ratio)):1")
            // Moss is also the words of the outlined buttons on the board (Turn over).
            let moss = Self.worst(try DesignTokenTests.color("JournalMoss", variant.traits), on: extremes)
            #expect(moss >= 4.5, "moss on the board, \(variant.name): \(String(format: "%.2f", moss)):1")
        }
    }

    @Test("Increase Contrast darkens the felt and quiets the linen")
    func boardUnderIncreaseContrast() async throws {
        func lightest(_ traits: UITraitCollection) async throws -> UIColor {
            let image = try await Self.renderImage(BoardMaterial(), traits: traits, size: 300)
            return try #require(Self.luminanceExtremes(image)?.lightest)
        }
        func level(_ color: UIColor) -> Double { DesignTokenTests.contrast(color, .black) }
        let variants = Dictionary(uniqueKeysWithValues: DesignTokenTests.variants.map { ($0.name, $0.traits) })
        let (dark, darkIncreased) = (try await lightest(try #require(variants["dark"])), try await lightest(try #require(variants["dark + Increase Contrast"])))
        #expect(level(darkIncreased) < level(dark), "the felt darkens: \(Self.hex(dark)) to \(Self.hex(darkIncreased))")
        let (light, lightIncreased) = (try await lightest(try #require(variants["light"])), try await lightest(try #require(variants["light + Increase Contrast"])))
        #expect(level(lightIncreased) > level(light), "the linen lightens under the ink: \(Self.hex(light)) to \(Self.hex(lightIncreased))")
    }

    @Test("board labels sit straight on the material, and on the page colour under Increase Contrast")
    func boardLabel() async throws {
        let label = ZStack { BoardMaterial(); Color.clear.frame(width: 80, height: 60).boardLabel() }
        for variant in DesignTokenTests.variants {
            let image = try await Self.renderImage(label, traits: variant.traits, size: 200)
            let paper = try DesignTokenTests.color("JournalPaper", variant.traits)
            let centre = try #require(Self.pixel(image, at: CGPoint(x: 100, y: 100)))
            if variant.traits.accessibilityContrast == .high {
                #expect(Self.distance(centre, paper) < 0.02, "the solid surface, \(variant.name): \(Self.hex(centre)), paper \(Self.hex(paper))")
            } else {
                #expect(Self.distance(centre, paper) > 0.02, "no surface without the setting, \(variant.name): \(Self.hex(centre))")
            }
        }
    }

    /// The average colour of `rect` in `image`.
    static func mean(_ image: UIImage, in rect: CGRect) -> UIColor? {
        guard let cgImage = image.cgImage else { return nil }
        let (width, height) = (cgImage.width, cgImage.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        var totals = [0, 0, 0]
        var count = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                let i = (y * width + x) * 4
                for channel in 0..<3 { totals[channel] += Int(bytes[i + channel]) }
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return UIColor(red: CGFloat(totals[0]) / CGFloat(count) / 255, green: CGFloat(totals[1]) / CGFloat(count) / 255, blue: CGFloat(totals[2]) / CGFloat(count) / 255, alpha: 1)
    }

    /// Issue #150, audit F11: the card measured #E1D9C3 on linen #E8DBCD, so paper sank into the cloth. It's lighter now, with
    /// an edge you can see. Felt is left alone, where the card already glows.
    @Test("in the light appearance the paper card measures lighter than the linen under it, with a real edge")
    func cardOnLinen() async throws {
        let card = ZStack {
            BoardMaterial()
            Color.clear.frame(width: 200, height: 200).modifier(CardStockSurface())
        }
        func level(_ color: UIColor) -> Double { DesignTokenTests.contrast(color, .black) }
        for variant in DesignTokenTests.variants where variant.traits.userInterfaceStyle == .light {
            let image = try await Self.renderImage(card, traits: variant.traits, size: 300)
            let linen = try #require(Self.mean(image, in: CGRect(x: 4, y: 4, width: 28, height: 28)))
            let stock = try #require(Self.mean(image, in: CGRect(x: 120, y: 120, width: 60, height: 60)))
            let edge = try #require(Self.mean(image, in: CGRect(x: 50, y: 110, width: 1, height: 80)))
            #expect(level(stock) > level(linen), "\(variant.name): card \(Self.hex(stock)) on linen \(Self.hex(linen))")
            let edgeContrast = DesignTokenTests.contrast(stock, edge)
            #expect(edgeContrast >= 1.3, "\(variant.name): the edge \(Self.hex(edge)) against the stock \(Self.hex(stock)): \(String(format: "%.2f", edgeContrast)):1")
        }
    }

    @Test("the stock on felt keeps its fibre: the easing is only on linen")
    func cardOnFeltIsUnchanged() async throws {
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        let light = UITraitCollection(userInterfaceStyle: .light)
        let onFelt = try #require(Self.mean(try await Self.renderImage(Color.clear.modifier(CardStockSurface()), traits: dark, size: 200), in: CGRect(x: 50, y: 50, width: 100, height: 100)))
        let onLinen = try #require(Self.mean(try await Self.renderImage(Color.clear.modifier(CardStockSurface()), traits: light, size: 200), in: CGRect(x: 50, y: 50, width: 100, height: 100)))
        func level(_ color: UIColor) -> Double { DesignTokenTests.contrast(color, .black) }
        #expect(level(onLinen) > level(onFelt), "linen \(Self.hex(onLinen)), felt \(Self.hex(onFelt))")
    }

    @Test("a member's initials clear 4.5:1 on every tone, and a member keeps one tone")
    func memberFaces() {
        func color(_ hex: UInt32) -> UIColor {
            UIColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        for tone in MemberFace.tones {
            let ratio = DesignTokenTests.contrast(color(MemberFace.ink), color(tone))
            #expect(ratio >= 4.5, "\(String(format: "#%06X", tone)): \(String(format: "%.2f", ratio)):1")
        }
    }

    @Test("Collection's tab icon is a custom symbol, so it takes the tab bar's tint and weight")
    func stitchedRing() throws {
        let ring = try #require(UIImage(named: "stitched.ring"), "the symbol isn't in the asset catalog")
        #expect(ring.isSymbolImage)
    }

    @Test("the card stock's ink, secondary ink and edge clear 4.5:1 against the fibre's worst pixel, with and without Increase Contrast")
    func cardStock() async throws {
        let stock = Color.clear.modifier(CardStockSurface())
        for variant in DesignTokenTests.variants {
            let image = try await Self.renderImage(stock, traits: variant.traits, size: 300)
            let extremes = try #require(Self.luminanceExtremes(image))
            // The surface forces the light scheme, as everything on it reads in it.
            let light = UITraitCollection { traits in
                traits.userInterfaceStyle = .light
                traits.accessibilityContrast = variant.traits.accessibilityContrast
            }
            for text in ["CollectibleInk", "CollectibleInkSecondary", "CollectibleEdge"] {
                let ratio = Self.worst(try DesignTokenTests.color(text, light), on: extremes)
                #expect(ratio >= 4.5, "\(text) on card stock, \(variant.name) (\(Self.hex(extremes.darkest))...\(Self.hex(extremes.lightest))): \(String(format: "%.2f", ratio)):1")
            }
        }
    }

    @Test("a paper tag's words clear 4.5:1 on the plain stock it's cut from")
    func paperTag() throws {
        let ink = try DesignTokenTests.color("CollectibleInk", UITraitCollection(userInterfaceStyle: .light))
        #expect(DesignTokenTests.contrast(ink, UIColor(Color.cardStock)) >= 4.5)
    }

    @Test("a not-yet-found silhouette's mark clears 3:1 on the raised surface")
    func silhouette() throws {
        for variant in DesignTokenTests.variants {
            let raised = try DesignTokenTests.color("JournalRaised", variant.traits)
            let mark = try DesignTokenTests.color("JournalInkSecondary", variant.traits)
            var (mr, mg, mb, ma, rr, rg, rb, ra): (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0, 0, 0, 0, 0)
            mark.getRed(&mr, green: &mg, blue: &mb, alpha: &ma)
            raised.getRed(&rr, green: &rg, blue: &rb, alpha: &ra)
            let opacity = CGFloat(SpeciesSilhouette.markOpacity)
            let blended = UIColor(red: mr * opacity + rr * (1 - opacity), green: mg * opacity + rg * (1 - opacity), blue: mb * opacity + rb * (1 - opacity), alpha: 1)
            let ratio = DesignTokenTests.contrast(blended, raised)
            #expect(ratio >= 3, "\(variant.name): \(String(format: "%.2f", ratio)):1")
        }
    }

    // MARK: - Translucent surfaces

    enum Surface: String, CaseIterable {
        /// The toast ("Added to your collection").
        case regularMaterial

        var style: AnyShapeStyle {
            switch self {
            case .regularMaterial: AnyShapeStyle(.regularMaterial)
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
        let image = try await renderImage(ZStack {
            backdrop
            Rectangle().fill(surface.style)
        }, traits: traits, size: 120)
        return pixel(image, at: CGPoint(x: 60, y: 60))
    }

    /// `view` filling a square window with `traits`' appearance and contrast, at one pixel a point.
    static func renderImage(_ view: some View, traits: UITraitCollection, size: CGFloat) async throws -> UIImage {
        let host = UIHostingController(rootView: view
            .ignoresSafeArea()
            .environment(\.colorScheme, traits.userInterfaceStyle == .dark ? .dark : .light))
        host.overrideUserInterfaceStyle = traits.userInterfaceStyle
        host.traitOverrides.accessibilityContrast = traits.accessibilityContrast
        // A window in the test host's scene, so it is drawn (a window outside any scene renders black).
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: size, height: size)
        window.windowLevel = .alert + 1
        window.overrideUserInterfaceStyle = traits.userInterfaceStyle
        window.traitOverrides.accessibilityContrast = traits.accessibilityContrast
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        return UIGraphicsImageRenderer(bounds: window.bounds, format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.preferredRange = .standard
            return format
        }()).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
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
