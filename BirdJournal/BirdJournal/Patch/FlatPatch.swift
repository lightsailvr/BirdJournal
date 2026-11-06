import SwiftUI
import UIKit

/// A patch as a plain picture, lit once from the share image's fixed light (issue #150): for the widget, which can't run a
/// shader, and the run recap, which goes into an image. Without its pictures it's the edition's blank, with the bird's name
/// on its tag. Needs the GPU, so only while the app is in front.
enum FlatPatch {
    /// The patch's longest side, in points; its shadow gets `room` on each side.
    private static let room: CGFloat = 14

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
}
