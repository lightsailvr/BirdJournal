import SwiftUI

/// The app's colours as the widget extension can reach them: the extension has none of the app's asset catalog, and a widget
/// is archived, so colours are chosen from the appearance the view is drawn in (the same values as `JournalInk` and friends,
/// and `DesignTokenTests` measures those).
nonisolated enum GlanceInk {
    private static func color(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    static func page(_ scheme: ColorScheme) -> Color { color(scheme == .dark ? 0x10292D : 0xEEF1EC) }

    static func ink(_ scheme: ColorScheme, _ contrast: ColorSchemeContrast) -> Color {
        switch (scheme, contrast) {
        case (.dark, .increased): color(0xFFFFFF)
        case (.dark, _): color(0xF5F1E7)
        case (_, .increased): color(0x0A2124)
        default: color(0x15363A)
        }
    }

    static func secondary(_ scheme: ColorScheme, _ contrast: ColorSchemeContrast) -> Color {
        switch (scheme, contrast) {
        case (.dark, .increased): color(0xCFDDD9)
        case (.dark, _): color(0xA9BFBA)
        case (_, .increased): color(0x2F4749)
        default: color(0x4A6366)
        }
    }

    static func rule(_ scheme: ColorScheme, _ contrast: ColorSchemeContrast) -> Color {
        switch (scheme, contrast) {
        case (.dark, .increased): color(0x6E8E8A)
        case (.dark, _): color(0x2C5054)
        case (_, .increased): color(0x7C908B)
        default: color(0xC5D1CC)
        }
    }

    /// The tint of a set's edition, `PatchEdition.tint`'s colorsets as the extension can reach them; a set the app doesn't know, or
    /// none, keeps today's aqua. Increase Contrast takes the ink, which measures highest on every surface here.
    static func tint(setID: String?, _ scheme: ColorScheme, _ contrast: ColorSchemeContrast) -> Color {
        if contrast == .increased { return ink(scheme, contrast) }
        let dark = scheme == .dark
        switch setID {
        case "us-ca-la": return color(dark ? 0xC8CF6B : 0x454B18)
        case "us-ca-sd": return color(dark ? 0x8FC7E3 : 0x184C6B)
        case "us-ca-bay": return color(dark ? 0xC9D4D6 : 0x3D494F)
        case "us-ca-desert": return color(dark ? 0xE9B099 : 0x703622)
        case "us-fl-orlando": return color(dark ? 0x7FD3C4 : 0x0B5048)
        default: return color(dark ? 0xBCE3D9 : 0x15363A)
        }
    }
}

/// A set's thread outside the app's own screens: the same stitches as `ThreadProgress`, at rest, since a widget draws one frame
/// and has nothing to sew forward with.
struct GlanceProgress: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    let sewn: Int
    let total: Int
    let tint: Color

    private static let height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            let count = Stitches.count(width: proxy.size.width, height: Self.height)
            ZStack {
                Stitches(count: count, sewn: Double(count))
                    .fill(GlanceInk.ink(scheme, contrast).opacity(contrast == .increased ? 0.4 : 0.22))
                Stitches(count: count, sewn: Double(Stitches.sewn(value: Double(sewn), total: Double(total), stitches: count, countsBirds: true)))
                    .fill(tint)
            }
        }
        .frame(height: Self.height)
        .accessibilityHidden(true)
    }
}
