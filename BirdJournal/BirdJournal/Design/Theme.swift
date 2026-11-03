import SwiftUI
import UIKit

/// The app's design tokens: Featherguild design guide 1.0, page 9 (issue #116, replacing #28's field-journal palette).
/// Deep teal and warm ivory: a teal page with ivory ink in the dark appearance, an ivory page with teal ink in the light
/// one, each with an Increase Contrast variant, all from the asset catalog so the system picks the variant. The guide's
/// values are starting tokens; the secondary ink, the rules and the text on an action are derived here, and
/// `DesignTokenTests` measures every text pairing in all four variants. Gold has one job, the personal-first Legendary
/// (`Color.goldInk`, in `Collectible.swift`); shared goals take the lavender accent; bird art keeps its own colours.
extension Color {
    /// The page: #10292D dark, #F4F2E9 light.
    static let paper = Color("JournalPaper")
    /// Grouped rows, panels and thumbnail placeholders: #193A3D dark, #DFEAE5 light.
    static let raised = Color("JournalRaised")
    /// Primary text: #F5F1E7 dark, #15363A light.
    static let ink = Color("JournalInk")
    /// Supporting text, at least 4.5:1 on the page and on a raised surface.
    static let inkSecondary = Color("JournalInkSecondary")
    /// Primary actions, links and the selected tab: aqua #BCE3D9 dark, teal #15363A light.
    static let moss = Color("JournalMoss")
    /// Text on a primary action's fill.
    static let mossText = Color("JournalMossText")
    /// Fine separators; decorative, stronger under Increase Contrast.
    static let rule = Color("JournalRule")
    /// The quiet lavender of shared goals (#B9BEDD dark, #E8E6F0 light): a fill, never gold.
    static let sharedGoal = Color("JournalSharedGoal")
    /// Text and marks on a `sharedGoal` fill.
    static let onSharedGoal = Color("JournalOnSharedGoal")
    /// Errors and destructive actions in a page (issue #119): brick #A3322A light, salmon #F4A79B dark, at least 5.5:1
    /// on the page and a raised surface. The system red measured 3.2:1 on the light page and 3.6:1 on the dark raised
    /// surface, under the 4.5:1 text needs.
    static let alert = Color("JournalAlert")
}

/// The type scale (design guide page 8): the system serif (New York) for titles, names and the tale, the system sans
/// for every control and supporting detail, all on native text styles so Dynamic Type scales them.
enum JournalFont {
    /// Page titles, about 34 pt.
    static let largeTitle = Font.system(.largeTitle, design: .serif, weight: .regular)
    /// Species names on a detail page, about 28 pt.
    static let title = Font.system(.title, design: .serif, weight: .regular)
    /// Section titles, about 22 pt.
    static let section = Font.system(.title2, design: .serif, weight: .regular)
    /// Row titles and card names, about 20 pt.
    static let heading = Font.system(.title3, design: .serif, weight: .regular)
    /// A name in a compact row, 17 pt serif.
    static let rowTitle = Font.system(.body, design: .serif, weight: .medium)
    static let body = Font.body
    static let supporting = Font.subheadline
    static let attribution = Font.footnote
    static let scientific = Font.system(.subheadline, design: .serif).italic()
}

/// The card's type (design guide pages 5 and 8): the bird's name upright, the story title upright and smaller, the lore
/// in a true italic serif with generous leading, the edition in small capitals, and a quiet sans footer.
enum CardFont {
    /// The bird's name on a card's front, about 28 pt, upright.
    static let birdName = Font.system(.title, design: .serif, weight: .semibold)
    /// The scientific name under it, italic.
    static let scientific = Font.system(.subheadline, design: .serif).italic()
    /// The story title, about 20 pt, upright.
    static let storyTitle = Font.system(.title3, design: .serif, weight: .medium)
    /// The lore excerpt: New York's true italic at 16 pt (callout).
    static let lore = Font.system(.callout, design: .serif).italic()
    /// The lore's extra leading, in points.
    static let loreLeading: CGFloat = 5
    /// "CITRUS EDITION", "LEGENDARY · YOUR FIRST": the edition line, set in capitals with open tracking.
    static let edition = Font.system(.caption, design: .serif, weight: .semibold)
    static let editionTracking: CGFloat = 1.6
    /// The edition line on a tile.
    static let editionCompact = Font.system(.caption2, design: .serif, weight: .semibold)
    static let editionCompactTracking: CGFloat = 1
    /// A tile's name, about 17 pt.
    static let tileName = Font.system(.headline, design: .serif, weight: .semibold)
    /// A tile's story title, about 15 pt.
    static let tileStoryTitle = Font.system(.subheadline, design: .serif, weight: .medium)
    /// The footer and the art credit: system sans, quieter than the story.
    static let footer = Font.footnote
    static let credit = Font.caption2
}

enum JournalLayout {
    /// Horizontal content margin.
    static let margin: CGFloat = 22
    static let rowGap: CGFloat = 14
    static let sectionGap: CGFloat = 28
    static let cornerRadius: CGFloat = 14
    static let thumbnailRadius: CGFloat = 10
    /// Primary actions are taller than the 44 pt minimum.
    static let primaryActionHeight: CGFloat = 54
}

extension JournalFont {
    /// The navigation bar's titles in the serif, matching the in-page headings; set once at launch.
    @MainActor
    static func applyNavigationBarAppearance() {
        let appearance = UINavigationBar.appearance()
        if let large = UIFont.preferredFont(forTextStyle: .largeTitle).fontDescriptor.withDesign(.serif) {
            appearance.largeTitleTextAttributes = [.font: UIFont(descriptor: large, size: 0)]
        }
        if let inline = UIFont.preferredFont(forTextStyle: .headline).fontDescriptor.withDesign(.serif) {
            appearance.titleTextAttributes = [.font: UIFont(descriptor: inline, size: 0)]
        }
    }
}

/// The primary action of a page: a full-width moss button with the label centred, 54 pt tall.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.mossText)
            .frame(maxWidth: .infinity, minHeight: JournalLayout.primaryActionHeight)
            .background(Color.moss.opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45), in: RoundedRectangle(cornerRadius: JournalLayout.cornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: JournalLayout.cornerRadius, style: .continuous))
    }
}

/// A secondary action: an outlined moss capsule, 44 pt tall, faded when disabled.
struct OutlinedButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.moss)
            .padding(.horizontal, 16)
            .frame(minHeight: 40)
            .background(Color.moss.opacity(configuration.isPressed ? 0.15 : 0), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.moss, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var journalPrimary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == OutlinedButtonStyle {
    static var journalOutlined: OutlinedButtonStyle { OutlinedButtonStyle() }
}

/// Lays a screen out on paper with the journal's margins: the standard scroll container for the tabs.
struct PaperPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, JournalLayout.margin)
                .padding(.bottom, JournalLayout.sectionGap)
        }
        .background(Color.paper)
        .scrollContentBackground(.hidden)
    }
}

extension View {
    /// The paper background behind a list-based screen.
    func paperList() -> some View {
        scrollContentBackground(.hidden).background(Color.paper)
    }
}

/// A section title in the serif with a fine rule under it.
struct SectionTitle: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(JournalFont.section)
                .foregroundStyle(Color.ink)
            Rectangle().fill(Color.rule).frame(height: 1)
        }
        .padding(.top, JournalLayout.sectionGap)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A fine rule between rows.
struct RowRule: View {
    var body: some View {
        Rectangle().fill(Color.rule).frame(height: 1)
    }
}

/// Something that went wrong and what to do about it, on a raised card: the recoverable error notice.
struct ErrorNotice<Action: View>: View {
    let title: String
    var message: String?
    var symbol = "exclamationmark.triangle"
    @ViewBuilder var action: Action

    init(_ title: String, message: String? = nil, symbol: String = "exclamationmark.triangle", @ViewBuilder action: () -> Action = { EmptyView() }) {
        self.title = title
        self.message = message
        self.symbol = symbol
        self.action = action()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.ink)
            if let message {
                Text(message)
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            action
                .buttonStyle(.journalOutlined)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.raised, in: RoundedRectangle(cornerRadius: JournalLayout.cornerRadius, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

/// A brief acknowledgment at the bottom of a screen ("Added to your journal") with an optional Undo, shown for a few
/// seconds. The screen that shows it picks the transition: a slide, or a fade under Reduce Motion.
struct Toast: View {
    let text: String
    var undo: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.moss)
            Text(text)
                .font(JournalFont.supporting.weight(.medium))
                .foregroundStyle(Color.ink)
            if let undo {
                Spacer(minLength: 8)
                Button("Undo", action: undo)
                    .font(JournalFont.supporting.weight(.semibold))
                    .foregroundStyle(Color.moss)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.rule, lineWidth: 1))
        .padding(.horizontal, JournalLayout.margin)
        .accessibilityElement(children: .combine)
    }
}

extension DynamicTypeSize {
    /// Whether rows should stack their thumbnail, text and control instead of sitting side by side.
    var stacksRows: Bool { isAccessibilitySize }
}

/// A row's contents side by side, or stacked at accessibility text sizes so names and controls keep their room.
struct AdaptiveRow<Content: View>: View {
    let stacked: Bool
    var spacing: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: spacing))
        layout { content }
    }
}
