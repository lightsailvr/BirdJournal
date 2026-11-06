import Album
import Pack
import SwiftUI

/// What stands for a bird on a row (issue #150, V2): your own photo where the row is about a sighting, since that's evidence; else
/// your patch if you have one in this row's context; else the reference photo.
enum RowPictureSource: Equatable {
    case ownPhoto(path: String)
    case patch(scientificName: String, setID: String?)
    case reference(URL?)

    /// - Parameter ownPhoto: the sighting's original photo; nil on a row that isn't about a sighting.
    static func of(ownPhoto: String? = nil, patch: CardCollection.Patch?, reference: URL?) -> RowPictureSource {
        if let ownPhoto { return .ownPhoto(path: ownPhoto) }
        if let patch { return .patch(scientificName: patch.scientificName, setID: patch.placement.setID) }
        return .reference(reference)
    }
}

/// A row's picture, at `side` points at the default text size. VoiceOver skips it: the row's words say what it means.
struct RowPicture: View {
    let source: RowPictureSource
    var side: CGFloat = 67

    var body: some View {
        Group {
            switch source {
            case .ownPhoto(let path):
                FrameImage(frameImagePath: path)
                    .clipShape(RoundedRectangle(cornerRadius: JournalLayout.thumbnailRadius, style: .continuous))
            case .patch(let scientificName, let setID):
                RowPatch(scientificName: scientificName, setID: setID)
            case .reference(let url):
                PackImage(url: url)
                    .clipShape(RoundedRectangle(cornerRadius: JournalLayout.thumbnailRadius, style: .continuous))
            }
        }
        .rowPicture(side)
        .accessibilityHidden(true)
    }
}

/// A patch on a row, standing for the bird: `PatchView`, on its two-at-a-time decode queue, as a plain bitmap under the shader,
/// so a row that redraws every second never decodes it again. The bird's name is in type beside it, so a patch without its
/// painting is the edition's blank, with no paper tag to read at this size. Whoever shows it holds the light
/// (`holdsPatchLight`).
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

/// A row's picture slot, a patch or a photo: its side at the default size, growing with the text up to the point where the row
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
