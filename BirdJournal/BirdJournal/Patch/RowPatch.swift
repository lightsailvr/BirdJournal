import Pack
import SwiftUI

/// A patch on a row, standing for the bird (issue #150, V2): `PatchView`, on its two-at-a-time decode queue, as a plain bitmap
/// under the shader, so a row that redraws every second never decodes it again. The bird's name is in type beside it, so a
/// patch without its painting is the edition's blank, with no paper tag to read at this size. Whoever shows it holds the
/// light (`holdsPatchLight`).
struct RowPatch: View {
    @Environment(PackLibrary.self) private var library
    let scientificName: String
    /// The patch's set, nil for Uncharted.
    let setID: String?

    var body: some View {
        PatchView(art: library.patchArt(scientificName: scientificName, setID: setID), edition: PatchEdition.of(setID: setID))
    }
}

/// A row's picture slot, a patch or a photo: 67 pt at the default size, growing with the text up to the point where the row
/// has stacked and the picture would crowd out the words.
private struct RowPictureSize: ViewModifier {
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 67

    func body(content: Content) -> some View {
        content.frame(width: min(side, 120), height: min(side, 120))
    }
}

extension View {
    func rowPicture() -> some View {
        modifier(RowPictureSize())
    }
}
