import SwiftUI
import UIKit

/// The field journal's design tokens (issue #28): warm paper, ink and moss in the light appearance, forest charcoal,
/// warm ivory and sage in the dark one, each with an Increase Contrast variant, all from the asset catalog so the
/// system picks the variant. Headings are set in the system serif, everything else in the system sans.
extension Color {
    /// The main content surface.
    static let paper = Color("JournalPaper")
    /// Grouped rows, cards and thumbnail placeholders.
    static let raised = Color("JournalRaised")
    static let ink = Color("JournalInk")
    static let inkSecondary = Color("JournalInkSecondary")
    /// Primary actions and the selected tab.
    static let moss = Color("JournalMoss")
    /// Text on a moss fill.
    static let mossText = Color("JournalMossText")
    /// Fine separators.
    static let rule = Color("JournalRule")
}

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

/// A secondary action: an outlined moss capsule, 44 pt tall.
struct OutlinedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.moss)
            .padding(.horizontal, 16)
            .frame(minHeight: 40)
            .background(Color.moss.opacity(configuration.isPressed ? 0.15 : 0), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.moss, lineWidth: 1))
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
