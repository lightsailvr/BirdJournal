import Album
import Pack
import SwiftUI

/// A set's cover as a printed plate (issue #150, A1): the painting inside a fine keyline, with the "AI illustration" credit printed
/// under it. It goes on card stock (`CardStockSurface(.plate)`), where the margin around it is the paper's. Listen's hero isn't
/// a plate: it stays full-bleed.
struct PlatePicture: View {
    /// The reference's plate, 742 by 355, cropped from the middle of a 16:9 cover.
    static let aspect: CGFloat = 742 / 355

    /// The mock's, opaque and outside the picture, so it holds over dark trees as well as a pale sky.
    private static let keyline = Color(hex: 0xAFAF99)
    /// The mock's one CSS pixel, at this screen's width: four of the device's.
    private static let keylineWidth: CGFloat = 4 / 3

    let setID: String
    var aspect = PlatePicture.aspect

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            SetCoverImage(setID: setID)
                .aspectRatio(aspect, contentMode: .fit)
                .padding(Self.keylineWidth)
                .background(Self.keyline)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Painted plate, AI illustration")
                .accessibilityAddTraits(.isImage)
            Text("AI illustration")
                .font(CardFont.credit)
                .foregroundStyle(Color.cardInk)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
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

    /// What VoiceOver hears for the Atlas's tile, the set's name first.
    static func spokenTile(set: PackSet, progress: SetProgress, isReadyOffline: Bool) -> String {
        ([set.name, "\(set.edition.name), \(set.species.count) birds", progress.sewnText] + (isReadyOffline ? ["Ready offline"] : []) + ["painted plate, AI illustration"])
            .joined(separator: ", ")
    }

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
            PlateProgress(progress: progress, showsReadyOffline: showsReadyOffline)
        }
        .plateStock()
    }

    private var name: some View {
        Text(set.name)
            .font(.system(size: titleSize, weight: .regular, design: .serif))
            .foregroundStyle(Color.cardInk)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
            // On a set's page VoiceOver starts here, not on the picture above it.
            .accessibilitySortPriority(1)
    }

    /// "Citrus edition, 160 birds".
    private var edition: some View {
        Text("\(set.edition.name), \(set.species.count) birds")
            .font(JournalFont.supporting)
            .foregroundStyle(Color.cardInk)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The thread on paper and "3 of 160 sewn", in the full ink, and "Ready offline" apart from it.
struct PlateProgress: View {
    let progress: SetProgress
    var showsReadyOffline = false

    var body: some View {
        ThreadProgress(progress, onPaper: true)
            .accessibilityHidden(true)
            .padding(.top, 13)
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                sewn
                Spacer(minLength: 8)
                if showsReadyOffline { ReadyOffline(ink: .cardInk) }
            }
            VStack(alignment: .leading, spacing: 4) {
                sewn
                if showsReadyOffline { ReadyOffline(ink: .cardInk) }
            }
        }
        .padding(.top, 8)
    }

    private var sewn: some View {
        Text(progress.sewnText)
            .font(JournalFont.supporting)
            .foregroundStyle(Color.cardInk)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension View {
    /// A full-width plate's margin and card stock.
    func plateStock() -> some View {
        padding(.horizontal, 11)
            .padding(.top, 11)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(CardStockSurface(.plate))
    }
}
