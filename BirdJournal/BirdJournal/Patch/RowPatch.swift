import Album
import Pack
import SwiftUI

/// What stands for a bird on a row (issue #150, V2): your own photo where the row is about a sighting, since that's evidence; else
/// your patch if you have one in this row's context; else the reference photo.
enum RowPictureSource: Equatable {
    /// A glasses frame is cropped to the bird, as the album crops it; a photo the birder chose isn't.
    case ownPhoto(path: String, isGlassesFrame: Bool)
    case patch(scientificName: String, setID: String?)
    case reference(URL?)
    /// A bird still out there, on a set's row: its shape, or the glyph when there's none (nil).
    case silhouette(URL?)

    /// A row about something other than a sighting.
    static func of(patch: CardCollection.Patch?, reference: URL?) -> RowPictureSource {
        if let patch { return .patch(scientificName: patch.scientificName, setID: patch.placement.setID) }
        return .reference(reference)
    }

    /// A row about a sighting.
    static func of(sighting: Sighting, patch: CardCollection.Patch?, reference: URL?) -> RowPictureSource {
        if let path = CardText.originalPhotoPath(sighting) {
            return .ownPhoto(path: path, isGlassesFrame: path == sighting.frameImagePath)
        }
        return of(patch: patch, reference: reference)
    }

    /// An Atlas row: your patch in this pack's set. By scientific name, since a pack's label isn't always the one a sighting has.
    static func of(species: PackSpecies, in pack: SpeciesPack, collection: CardCollection) -> RowPictureSource {
        of(
            patch: collection.patch(scientificName: species.scientificName, setID: pack.info.id),
            reference: species.photos.first.map(pack.lensImageURL(for:))
        )
    }

    /// A set's row: your patch in that set, else the bird's silhouette, if the set's own pack is on the phone and has one.
    static func ofSetRow(scientificName: String, setID: String, patch: CardCollection.Patch?, pack: SpeciesPack?) -> RowPictureSource {
        if patch != nil { return .patch(scientificName: scientificName, setID: setID) }
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
            case .patch(let scientificName, let setID):
                RowPatch(scientificName: scientificName, setID: setID)
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
