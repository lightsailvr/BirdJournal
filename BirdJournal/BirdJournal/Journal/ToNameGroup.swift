import SwiftUI

/// "To name" (issue #188, of #185), at the top of the Collection's Sightings: every photo still waiting for its bird's name,
/// newest first, from this run or one weeks ago. They are listed apart from the days because they are not sightings yet:
/// they count in no total above, and each joins its own day, the day it was taken, once named. The group is there only
/// while something waits.
struct ToNameGroup: View {
    let unnamed: [UnnamedSighting]
    var top = JournalLayout.sectionGap
    let name: (UnnamedSighting) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(UnnamedSightingText.toName, top: top)
            Text(UnnamedSightingText.toNameNote)
                .font(JournalFont.supporting)
                .foregroundStyle(Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            VStack(spacing: 0) {
                ForEach(unnamed) { waiting in
                    UnnamedSightingRow(unnamed: waiting) { name(waiting) }
                    RowRule()
                }
            }
            .padding(.top, 6)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("to-name")
    }
}
