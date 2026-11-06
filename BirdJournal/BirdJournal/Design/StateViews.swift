import SwiftUI

/// The one empty or unavailable state (issue #119, design guide page 16; the only one since issue #150): no patches yet, no
/// Guilds yet, a search with no match, nothing installed, a bird or set the phone no longer has. A quiet mark, a serif title,
/// plain words, and the useful next action where there is one, centred on the page in the tokens. The mark is decorative, so
/// VoiceOver reads the title, the words and the action. `.statePage()` centres one on a whole page.
struct StateNotice<Actions: View>: View {
    enum Mark {
        /// The perched finch in glasses, the mascot, for a page that's empty because nothing has happened yet.
        case drawing
        /// An SF Symbol on a raised disc.
        case symbol(String)
        /// A Guild's emblem, as `GuildEmblem` draws it.
        case emblem(GuildIdentity)
    }

    let title: String
    var message: String?
    var mark: Mark?
    /// The message's colour: on a material it stays in the full ink (`TokenPairingTests`).
    var messageInk: Color
    @ViewBuilder var actions: Actions

    init(_ title: String, message: String? = nil, mark: Mark? = nil, messageInk: Color = .inkSecondary, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.title = title
        self.message = message
        self.mark = mark
        self.messageInk = messageInk
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 14) {
            switch mark {
            case .drawing:
                PerchedFinch()
            case .symbol(let name):
                Image(systemName: name)
                    .font(.title2)
                    .foregroundStyle(Color.ink)
                    .frame(width: 60, height: 60)
                    .background(Color.raised, in: Circle())
                    .overlay(Circle().strokeBorder(Color.rule, lineWidth: 1))
                    .accessibilityHidden(true)
            case .emblem(let identity):
                GuildEmblem(identity: identity, size: 56)
                    .accessibilityHidden(true)
            case nil:
                EmptyView()
            }
            Text(title)
                .font(JournalFont.section)
                .foregroundStyle(Color.ink)
                .accessibilityAddTraits(.isHeader)
            if let message {
                Text(message)
                    .font(JournalFont.body)
                    .foregroundStyle(messageInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions
                .padding(.top, 6)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .accessibilityElement(children: .contain)
    }
}

extension View {
    /// A `StateNotice` as a whole page: centred on the paper, within the margins.
    func statePage() -> some View {
        padding(.horizontal, JournalLayout.margin)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.paper)
    }
}

/// The fuller explanation behind one plain line (issue #150): trust content stays word for word, a tap away, so it isn't a
/// wall of text on the way to a setting.
struct HowThisWorks: View {
    let paragraphs: [String]

    init(_ paragraphs: String...) {
        self.paragraphs = paragraphs
    }

    var body: some View {
        DisclosureGroup("How this works") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(paragraphs, id: \.self) { Text($0) }
            }
            .font(JournalFont.supporting)
            .foregroundStyle(Color.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(JournalFont.supporting)
        .accessibilityIdentifier("how-this-works")
    }
}

/// An error line inside a page or a list (issue #119): the alert token with a mark, so it reads as an error without
/// leaning on colour alone, at the text contrast the system red missed.
struct InlineError: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.circle")
        }
        .font(JournalFont.supporting)
        .foregroundStyle(Color.alert)
        .accessibilityElement(children: .combine)
    }
}
