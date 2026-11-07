import SwiftUI
import UIKit
import WidgetKit

/// The widget's face (issue #150): your latest patch on the app's own felt or linen, and how far along its set is. The patch
/// is a flat bitmap: nothing here has a shader, and a widget draws one frame. Tapping opens the patch's page.
struct LatestPatchWidgetView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    let snapshot: WidgetSnapshot
    let patchImage: UIImage?
    let family: WidgetFamily

    private var tint: Color { GlanceInk.tint(setID: snapshot.progress?.setID, scheme, contrast) }

    var body: some View {
        Group {
            if snapshot.latest == nil {
                empty
            } else if family == .systemSmall {
                small
            } else {
                medium
            }
        }
        // A fixed-size surface: the words are in the app at any size.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .widgetURL(snapshot.latest?.link.url)
        .containerBackground(for: .widget) { GlanceBoard() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snapshot.spokenText)
    }

    @ViewBuilder private var patch: some View {
        if let patchImage {
            Image(uiImage: patchImage)
                .resizable()
                .widgetAccentedRenderingMode(.fullColor)
                .scaledToFit()
        }
    }

    @ViewBuilder private var thread: some View {
        if let progress = snapshot.progress {
            VStack(alignment: .leading, spacing: 3) {
                GlanceProgress(sewn: progress.sewn, total: progress.total, tint: tint)
                Text(progress.sewnText)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(GlanceInk.secondary(scheme, contrast))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    private var small: some View {
        VStack(spacing: 4) {
            patch
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(snapshot.latest?.name ?? "")
                .font(.system(.footnote, design: .serif, weight: .medium))
                .foregroundStyle(GlanceInk.ink(scheme, contrast))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            thread
        }
    }

    private var medium: some View {
        HStack(spacing: 14) {
            patch
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.latest?.name ?? "")
                    .font(.system(.title3, design: .serif))
                    .foregroundStyle(GlanceInk.ink(scheme, contrast))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Text(snapshot.latest?.setName ?? "")
                    .font(.subheadline)
                    .foregroundStyle(GlanceInk.secondary(scheme, contrast))
                    .lineLimit(1)
                Spacer(minLength: 6)
                thread
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            // No patch, not even a blank, for a bird not found: Listen's mark, since that's where the first one starts.
            Image(systemName: "waveform")
                .font(.title2)
                .foregroundStyle(tint)
            Spacer(minLength: 0)
            Text(WidgetSnapshot.emptyText)
                .font(.system(family == .systemSmall ? .footnote : .body, design: .serif))
                .foregroundStyle(GlanceInk.ink(scheme, contrast))
                .lineLimit(3)
                .minimumScaleFactor(0.8)
            thread
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The felt or the linen under the patch, as `BoardMaterial` draws them. The textures are in both targets' catalogs.
struct GlanceBoard: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if scheme == .dark {
            Image("MaterialFelt")
                .resizable(resizingMode: .tile)
                .overlay(Color(.sRGB, red: 0x08 / 255, green: 0x1A / 255, blue: 0x1D / 255).opacity(contrast == .increased ? 0.85 : 0.6))
        } else {
            Image("MaterialLinen")
                .resizable(resizingMode: .tile)
                .overlay(Color.white.opacity(contrast == .increased ? 0.55 : 0.45))
        }
    }
}
