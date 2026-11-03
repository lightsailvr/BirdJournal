import SwiftUI

/// A designed state (issue #119, design guide page 16): no cards yet, no Guilds yet, a search with no match, nothing
/// installed. A quiet mark, a serif title, plain words, and the useful next action where there is one, centred on
/// the page in the tokens. The mark is decorative, so VoiceOver reads the title, the words and the action.
struct StateNotice<Actions: View>: View {
    enum Mark {
        /// The perched bird line drawing of the empty collection.
        case drawing
        /// An SF Symbol on a raised disc.
        case symbol(String)
    }

    let title: String
    let message: String
    var mark: Mark?
    @ViewBuilder var actions: Actions

    init(_ title: String, message: String, mark: Mark? = nil, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.title = title
        self.message = message
        self.mark = mark
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 14) {
            switch mark {
            case .drawing:
                PerchedBirdDrawing()
                    .frame(height: 110)
                    .accessibilityHidden(true)
            case .symbol(let name):
                Image(systemName: name)
                    .font(.title2)
                    .foregroundStyle(Color.ink)
                    .frame(width: 60, height: 60)
                    .background(Color.raised, in: Circle())
                    .overlay(Circle().strokeBorder(Color.rule, lineWidth: 1))
                    .accessibilityHidden(true)
            case nil:
                EmptyView()
            }
            Text(title)
                .font(JournalFont.section)
                .foregroundStyle(Color.ink)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(JournalFont.body)
                .foregroundStyle(Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            actions
                .padding(.top, 6)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .accessibilityElement(children: .contain)
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
