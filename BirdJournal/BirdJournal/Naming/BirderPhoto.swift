import Album
import ImageIO
import SwiftUI

/// The birder's photo in a slot, filled from the middle: a row's picture, and the head of "Name this bird". It takes no
/// touches (DECISIONS.md "Clipped images take no touches"), and is read at the slot's size: a camera's picture is twelve
/// megapixels or more.
///
/// A photo taken from the glasses is shown at the journal's crop (`FrameCrop.albumZoom`), the middle the lens's
/// viewfinder marked when the wearer framed the bird; the phone's camera's and a library photo are shown whole.
struct BirderPhoto: View {
    @Environment(\.frameStore) private var frameStore
    let path: String?
    /// The photo is the glasses' own: cropped to its middle, as the journal shows a glasses photo.
    var isGlassesFrame = false
    /// The longer side it is read at, in pixels: enough for a row's slot unless the slot is larger.
    var maxPixels = 360
    /// What stands in the slot until the photo is read, and when its file is gone.
    var placeholder: String? = "camera"
    @State private var image: UIImage?

    var body: some View {
        Color.raised
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .allowsHitTesting(false)
                } else if let placeholder {
                    Image(systemName: placeholder)
                        .foregroundStyle(Color.inkSecondary)
                }
            }
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: Shown(path: path, isGlassesFrame: isGlassesFrame)) {
                guard let path, let url = frameStore?.url(for: path) else { return }
                let side = maxPixels, zoom = isGlassesFrame ? FrameCrop.albumZoom : 1
                image = await Task.detached(priority: .userInitiated) { Self.fitted(at: url, maxPixels: side, zoom: zoom) }.value
            }
    }

    private struct Shown: Hashable {
        let path: String?
        let isGlassesFrame: Bool
    }

    /// The photo at `url` turned upright and no larger than `maxPixels` on its longer side. With a `zoom` above 1 it is
    /// the photo's middle at that zoom (`FrameCrop`), read large enough that the crop still has `maxPixels`.
    nonisolated static func fitted(at url: URL, maxPixels: Int, zoom: CGFloat = 1) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int((CGFloat(maxPixels) * max(zoom, 1)).rounded()),
        ]
        guard let whole = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        guard zoom > 1 else { return UIImage(cgImage: whole) }
        return FrameCrop.centerCrop(whole, zoom: zoom).map(UIImage.init(cgImage:))
    }
}
