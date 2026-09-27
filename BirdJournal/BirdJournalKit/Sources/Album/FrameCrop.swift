import CoreGraphics
import Foundation

/// The album's view of a stored camera frame (spec user story 37): the frame is kept whole on disk and shown as a
/// center crop, `zoom` times closer than the glasses saw it, since the bird is rarely more than a speck in the
/// wide camera field.
public enum FrameCrop {
    /// The album's crop: the middle half of each side.
    public static let albumZoom: CGFloat = 2

    /// The rectangle of `size` that a center crop at `zoom` keeps, on whole pixels and inside the frame. A zoom of
    /// 1 or less keeps the whole frame.
    public static func centerRect(in size: CGSize, zoom: CGFloat = albumZoom) -> CGRect {
        let zoom = max(zoom, 1)
        let width = (size.width / zoom).rounded(.down)
        let height = (size.height / zoom).rounded(.down)
        let x = ((size.width - width) / 2).rounded(.down)
        let y = ((size.height - height) / 2).rounded(.down)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// `image` cropped to `centerRect`, or nil if the image cannot be cropped.
    public static func centerCrop(_ image: CGImage, zoom: CGFloat = albumZoom) -> CGImage? {
        image.cropping(to: centerRect(in: CGSize(width: image.width, height: image.height), zoom: zoom))
    }
}
