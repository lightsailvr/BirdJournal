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

    /// The transfer pen's blue: what's not sewn yet.
    static func pen(_ scheme: ColorScheme) -> Color { color(scheme == .dark ? 0x9DB4EE : 0x3F5FA8) }

    /// The tint of a set's edition, the issue's table; a set the app doesn't know, or none, keeps today's aqua. Increase
    /// Contrast takes the ink, which measures highest on every surface here.
    static func tint(setID: String?, _ scheme: ColorScheme, _ contrast: ColorSchemeContrast) -> Color {
        if contrast == .increased { return ink(scheme, contrast) }
        let dark = scheme == .dark
        switch setID {
        case "us-ca-la": return color(dark ? 0xC8CF6B : 0x5C6420)
        case "us-ca-sd": return color(dark ? 0x8FC7E3 : 0x1E5F86)
        case "us-ca-bay": return color(dark ? 0xC9D4D6 : 0x4F5F66)
        case "us-ca-desert": return color(dark ? 0xE7A78E : 0x9A4A2F)
        case "us-fl-orlando": return color(dark ? 0x7FD3C4 : 0x0F6B60)
        default: return color(dark ? 0xBCE3D9 : 0x15363A)
        }
    }
}

/// Progress outside the app's own screens: today's bar (`SpeciesCollected`'s) behind one small seam, until `ThreadProgress`
/// lands (issue #150's slice 6) and takes this view's place. A widget draws one frame, so nothing here animates.
struct GlanceProgress: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    let sewn: Int
    let total: Int
    let tint: Color

    private var fraction: Double { total == 0 ? 0 : min(Double(sewn) / Double(total), 1) }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(GlanceInk.rule(scheme, contrast).opacity(0.7))
                Capsule().fill(tint).frame(width: max(sewn > 0 ? 6 : 0, geometry.size.width * fraction))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}
