import Pack
import SwiftUI

/// A field-guide download offered in a page, once (issue #223): what the birder gets, the download's own control with its
/// size, and "Not now", on the raised surface the page's other notices use. The control is the Atlas's (`PackTransferStatus`),
/// so the offer starts the same download, shows the same progress with its Cancel, and recovers from the same failures; nothing
/// downloads without a tap. It says whatever its caller gives it: #224's "Los Angeles is now a download" is this card with
/// other words.
struct FieldGuideOfferCard: View {
    @Environment(PackLibrary.self) private var library
    let title: String
    let message: String
    /// The download, as the index lists it.
    let descriptor: PackDescriptor
    /// "Not now": the caller remembers it.
    let dismiss: () -> Void

    var body: some View {
        let status = library.status(of: descriptor)
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(JournalFont.rowTitle)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(JournalFont.supporting)
                .foregroundStyle(Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            switch status {
            case .notInstalled:
                // Side by side while they fit; one over the other at the large sizes.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .bottom, spacing: 6) {
                        PackTransferStatus(status: status, descriptor: descriptor)
                        notNow(inset: 12)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        PackTransferStatus(status: status, descriptor: descriptor)
                        notNow(inset: 0)
                    }
                }
            case .failed:
                // What went wrong and its recovery, then the way out, on the same edge.
                PackTransferStatus(status: status, descriptor: descriptor)
                notNow(inset: 0)
            default:
                // Under way: its progress and Cancel are the answer now.
                PackTransferStatus(status: status, descriptor: descriptor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.raised, in: RoundedRectangle(cornerRadius: JournalLayout.cornerRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("field-guide-offer")
    }

    /// Quieter than Download, and still 44 points to the finger.
    /// - Parameter inset: room at its sides, beside Download; none under it, where its words start on the card's edge.
    private func notNow(inset: CGFloat) -> some View {
        Button {
            library.dismissFailure(id: descriptor.id)
            dismiss()
        } label: {
            Text("Not now")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.inkSecondary)
                .padding(.horizontal, inset)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.journalPress)
        .accessibilityHint(Self.notNowHint)
        .accessibilityIdentifier("field-guide-offer-not-now")
    }

    static let notNowHint = "Hides this offer. The download stays on the set's page in the Atlas."
}

extension FieldGuideOfferCard {
    /// The offer to a birder standing in `set`, whose field guide isn't on the phone.
    init(standingIn set: PackSet, descriptor: PackDescriptor, dismiss: @escaping () -> Void) {
        self.init(title: Self.placeTitle(set), message: Self.placeMessage(set), descriptor: descriptor, dismiss: dismiss)
    }

    /// "You're in the San Diego set": with "set" after it, every set's name reads as a sentence (the Pacific Northwest set, the
    /// California Deserts set).
    static func placeTitle(_ set: PackSet) -> String {
        "You're in the \(set.name) set"
    }

    /// What the download brings: the place's edition for the birds found there, and the field guide's pages.
    static func placeMessage(_ set: PackSet) -> String {
        "Its field-guide download brings the \(set.edition.name): the birds you find here are sewn as this set's patches, with its photos, sounds and field notes."
    }
}
