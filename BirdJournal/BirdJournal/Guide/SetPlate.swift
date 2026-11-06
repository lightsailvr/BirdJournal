import Album
import Pack
import SwiftUI

/// A set's cover as a printed plate (issue #150, A1): the painting inside a fine keyline, with the "AI illustration" credit printed
/// under it. It goes on card stock (`CardStockSurface(.plate)`), where the margin around it is the paper's. Listen's hero isn't
/// a plate: it stays full-bleed.
struct PlatePicture: View {
    /// The reference's plate, 742 by 355, cropped from the middle of a 16:9 cover.
    static let aspect: CGFloat = 742 / 355

    let setID: String
    var aspect = PlatePicture.aspect

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            SetCoverImage(setID: setID)
                .aspectRatio(aspect, contentMode: .fit)
                .overlay(Rectangle().strokeBorder(Color.cardEdge.opacity(0.55), lineWidth: 1))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Painted plate, AI illustration")
                .accessibilityAddTraits(.isImage)
            Text("AI illustration")
                .font(CardFont.credit)
                .foregroundStyle(Color.cardInkSecondary)
                .accessibilityHidden(true)
        }
    }
}

/// One set as a page of the book (the reference's `4-set-page.png`): its plate, its name beside "Citrus edition, 160 birds", the
/// thread on paper and "3 of 160 sewn". Everything on it reads in the light scheme (`CardStockSurface`), so the thread is the
/// edition's darker colour, as the mock draws it.
struct SetPlate: View {
    let set: PackSet
    let progress: SetProgress
    /// The Atlas's tile says so, keeping it apart from the birder's progress. A set's own page doesn't need it.
    var showsReadyOffline = false

    /// The mock's name at 1.34, between the type scale's title 2 and title.
    @ScaledMetric(relativeTo: .title) private var titleSize: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PlatePicture(setID: set.id)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    name
                    Spacer(minLength: 8)
                    edition
                }
                VStack(alignment: .leading, spacing: 2) {
                    name
                    edition
                }
            }
            .padding(.top, 2)
            ThreadProgress(progress)
                .accessibilityHidden(true)
                .padding(.top, 13)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    sewn
                    Spacer(minLength: 8)
                    if showsReadyOffline { ReadyOffline() }
                }
                VStack(alignment: .leading, spacing: 4) {
                    sewn
                    if showsReadyOffline { ReadyOffline() }
                }
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 11)
        .padding(.top, 11)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CardStockSurface(.plate))
    }

    private var name: some View {
        Text(set.name)
            .font(.system(size: titleSize, weight: .regular, design: .serif))
            .foregroundStyle(Color.cardInk)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    /// "Citrus edition, 160 birds".
    private var edition: some View {
        Text("\(set.edition.name), \(set.species.count) birds")
            .font(JournalFont.supporting)
            .foregroundStyle(Color.cardInk)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var sewn: some View {
        Text(progress.sewnText)
            .font(JournalFont.supporting)
            .foregroundStyle(Color.cardInkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
