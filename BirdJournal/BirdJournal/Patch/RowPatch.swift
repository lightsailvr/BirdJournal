import Album
import Pack
import SwiftUI

/// What stands for a bird on a row, and never a patch (the maintainer, issue #150: "patches should only be on the patches"). A
/// sighting's row has your own photo, else the Atlas's reference photo. A Species row and the Atlas's rows have the reference
/// photo, for a guidebook is how a bird looks. A bird still out there, on a set's row, has its silhouette.
enum RowPictureSource: Equatable {
    /// A glasses frame is cropped to the bird, as the album crops it; a photo the birder chose isn't.
    case ownPhoto(path: String, isGlassesFrame: Bool)
    case reference(URL?)
    /// A bird still out there, on a set's row: its shape, or the glyph when there's none (nil).
    case silhouette(URL?)

    /// A row about a sighting.
    static func of(sighting: Sighting, reference: URL?) -> RowPictureSource {
        if let path = CardText.originalPhotoPath(sighting) {
            return .ownPhoto(path: path, isGlassesFrame: CardText.originalPhotoIsGlassesFrame(sighting))
        }
        return .reference(reference)
    }

    /// A set's row: the reference photo of a bird you've found, else its silhouette, if the set's own pack is on the phone and has one.
    static func ofSetRow(scientificName: String, isFound: Bool, reference: URL?, pack: SpeciesPack?) -> RowPictureSource {
        if isFound { return .reference(reference) }
        guard let pack, let silhouette = pack.species(scientificName: scientificName)?.silhouette else { return .silhouette(nil) }
        return .silhouette(pack.silhouetteURL(for: silhouette))
    }
}

/// A row's picture, at `side` points at the default text size. VoiceOver skips it: the row's words say what it means.
struct RowPicture: View {
    let source: RowPictureSource
    var side: CGFloat = 67

    var body: some View {
        Group {
            switch source {
            case .ownPhoto(let path, let isGlassesFrame):
                FrameImage(frameImagePath: path, zoom: isGlassesFrame ? FrameCrop.albumZoom : 1)
                    .clipShape(RoundedRectangle(cornerRadius: JournalLayout.thumbnailRadius, style: .continuous))
            case .reference(let url):
                PackImage(url: url)
                    .clipShape(RoundedRectangle(cornerRadius: JournalLayout.thumbnailRadius, style: .continuous))
            case .silhouette(let url):
                SpeciesSilhouette(url: url)
                    .clipShape(RoundedRectangle(cornerRadius: JournalLayout.thumbnailRadius, style: .continuous))
            }
        }
        .rowPicture(side)
        .accessibilityHidden(true)
    }
}

/// A small patch standing for the bird, on a run's row and in a Guild goal's row of the month's patches: `PatchView`, on its
/// two-at-a-time decode queue, as a plain bitmap under the shader, so a row that redraws every second never decodes it again.
/// The bird's name is in type beside it or in what VoiceOver hears, so a patch without its painting is the edition's blank,
/// with no paper tag to read at this size. Whoever shows it holds the light (`holdsPatchLight`).
struct RowPatch: View {
    @Environment(PackLibrary.self) private var library
    let scientificName: String
    /// The patch's set, nil for Uncharted.
    let setID: String?
    /// Outlines the patch, as a calling bird's picture is outlined.
    var isCalling = false

    var body: some View {
        let edition = PatchEdition.of(setID: setID)
        PatchView(art: library.patchArt(scientificName: scientificName, setID: setID), edition: edition)
            .overlay {
                if isCalling {
                    Color.clear
                        .aspectRatio(edition.aspect, contentMode: .fit)
                        .overlay {
                            PatchOutline(shape: edition.shape)
                                .stroke(.tint, lineWidth: 2.5)
                        }
                        .allowsHitTesting(false)
                }
            }
    }
}

/// A row's picture slot: its side at the default size, growing with the text up to the point where the row
/// has stacked and the picture would crowd out the words.
private struct RowPictureSize: ViewModifier {
    @ScaledMetric private var side: CGFloat

    init(side: CGFloat) {
        _side = ScaledMetric(wrappedValue: side, relativeTo: .body)
    }

    func body(content: Content) -> some View {
        content.frame(width: min(side, 120), height: min(side, 120))
    }
}

extension View {
    func rowPicture(_ side: CGFloat = 67) -> some View {
        modifier(RowPictureSize(side: side))
    }
}
