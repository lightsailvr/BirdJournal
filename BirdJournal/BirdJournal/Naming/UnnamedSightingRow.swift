import Album
import SwiftUI

/// An unnamed sighting's row (issue #188, of #185), wherever one waits: under "Seen this run", in the run's review, and in the
/// Collection's "To name". The photo, "Unnamed sighting", whose photo it is and when it was taken, and "Name it", which opens
/// "Name this bird" for it. No bird's name and nothing earned: it is not a sighting yet.
struct UnnamedSightingRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let unnamed: UnnamedSighting
    let name: () -> Void

    var body: some View {
        // Its age moves on by the minute while it waits on a run's page.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            AdaptiveRow(stacked: typeSize.stacksRows) {
                BirderPhoto(path: unnamed.photoPath, isGlassesFrame: unnamed.isGlassesFrame)
                    .rowPicture()
                    .clipShape(RoundedRectangle(cornerRadius: JournalLayout.thumbnailRadius, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(UnnamedSightingText.title)
                        .font(JournalFont.rowTitle)
                        .foregroundStyle(Color.ink)
                    Text(NameBirdText.line(UnnamedSightingText.row(takenAt: unnamed.takenAt, now: context.date)))
                        .font(JournalFont.supporting)
                        .foregroundStyle(Color.inkSecondary)
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(UnnamedSightingText.nameIt, action: name)
                    .buttonStyle(.journalRowPill(isFilled: true))
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The whole row opens the naming, not only its button.
            .contentShape(Rectangle())
            .onTapGesture(perform: name)
            // One stop for VoiceOver, with the button's action.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(UnnamedSightingText.spoken(takenAt: unnamed.takenAt, now: context.date))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, name)
            .accessibilityHint("Opens Name this bird")
            .accessibilityInputLabels([UnnamedSightingText.nameIt, UnnamedSightingText.title])
            .accessibilityIdentifier("unnamed-row")
        }
    }
}

extension View {
    /// "Name this bird" for the unnamed sighting a row hands over, as a sheet over whatever shows the row.
    /// - Parameter added: told the add a naming there made, for a screen that shows its acknowledgment itself.
    func namesUnnamedSighting(_ naming: Binding<UnnamedSighting?>, added: ((RunSightings.Addition) -> Void)? = nil) -> some View {
        sheet(item: naming) { unnamed in
            NameBirdView(unnamed: unnamed, added: added) { naming.wrappedValue = nil }
        }
    }
}
