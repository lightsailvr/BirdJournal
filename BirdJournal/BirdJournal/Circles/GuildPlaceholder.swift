import SwiftUI

/// What a Guild screen shows while the server answers and nothing is known yet (issue #150): rows the shape of what's coming,
/// redacted, on the list's raised surface. VoiceOver hears "Loading" once.
struct GuildPlaceholder: View {
    var rows = 3

    var body: some View {
        ForEach(0..<rows, id: \.self) { row in
            HStack(spacing: 12) {
                Circle()
                    .fill(Color.inkSecondary.opacity(0.22))
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text("A bird in a Guild")
                        .font(JournalFont.rowTitle)
                        .foregroundStyle(Color.ink)
                    Text("Who found it, and where")
                        .font(JournalFont.supporting)
                        .foregroundStyle(Color.inkSecondary)
                }
            }
            .padding(.vertical, 6)
            .redacted(reason: .placeholder)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading")
            .accessibilityHidden(row > 0)
            .accessibilityIdentifier("guild-placeholder")
        }
    }
}
