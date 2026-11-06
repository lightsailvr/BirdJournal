import SwiftUI
import UIKit

/// A patch as a plain picture, lit once from the share image's fixed light (issue #150): for the widget, which can't run a
/// shader, and the run recap, which goes into an image. Without its pictures it's the edition's blank, with the bird's name
/// on its tag. Lighting needs the GPU, so only while the app is in front; `unlit` doesn't.
enum FlatPatch {
    /// The patch's longest side, in points; its shadow gets `room` on each side.
    static let room: CGFloat = 14

    @MainActor
    static func render(loaded: PatchTextures.Loaded?, edition: PatchEdition, tag: String?, width: CGFloat, scale: CGFloat) -> UIImage? {
        let height = width / max(edition.aspect, 1)
        let view = Color.clear
            .aspectRatio(edition.aspect, contentMode: .fit)
            .overlay {
                if let loaded {
                    LitPatch(loaded: loaded, ground: edition.twill, sewnTo: StitchTimeline.allSewn, room: room, fixedLight: PatchShareImage.light)
                } else {
                    PatchBlank(edition: edition, tag: tag)
                }
            }
            .frame(width: width, height: height)
            .padding(room)
            .environment(\.colorScheme, .light)
            .environment(\.dynamicTypeSize, .large)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        return renderer.uiImage
    }

    /// The painting as it is, in the same frame as a lit patch and cut to the edition's shape: no light and no shadow, and no
    /// GPU, so it can be drawn with the phone locked.
    static func unlit(loaded: PatchTextures.Loaded, edition: PatchEdition, width: CGFloat, scale: CGFloat) -> UIImage {
        let height = width / max(edition.aspect, 1)
        let frame = CGSize(width: width + room * 2, height: height + room * 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: frame, format: format).image { context in
            let face = CGRect(x: room + (width - height * edition.aspect) / 2, y: room, width: height * edition.aspect, height: height)
            context.cgContext.addPath(PatchOutline(shape: edition.shape).path(in: face).cgPath)
            context.cgContext.clip()
            UIImage(cgImage: loaded.colourBitmap).draw(in: face)
        }
    }
}
