import Album
import Pack
import SwiftUI

/// A stored glasses frame, cropped to its centre at the album's zoom and decoded off the main actor; a placeholder
/// while it loads or when the file is gone (iOS can purge frames that fell back to tmp). `zoom` 1 shows the whole frame.
struct FrameImage: View {
    @Environment(\.frameStore) private var frameStore
    let frameImagePath: String?
    var zoom: CGFloat = FrameCrop.albumZoom
    @State private var image: UIImage?

    var body: some View {
        // The picture is an overlay, so the slot keeps the size it was given and a wide frame is cropped, not laid
        // out at its own width.
        Color.raised
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "camera")
                        .foregroundStyle(Color.inkSecondary)
                }
            }
            .clipped()
            .task(id: frameImagePath) {
            image = nil
            guard let frameImagePath, let url = frameStore?.url(for: frameImagePath) else { return }
            let zoom = zoom
            image = await Task.detached(priority: .userInitiated) { Self.croppedFrame(at: url, zoom: zoom) }.value
        }
    }

    /// The frame at `url` cropped to its centre, keeping the JPEG's orientation. Read as data, not by path:
    /// `URL.path()` percent-encodes the space in "Application Support".
    nonisolated static func croppedFrame(at url: URL, zoom: CGFloat) -> UIImage? {
        guard let data = try? Data(contentsOf: url), let frame = UIImage(data: data), let cgImage = frame.cgImage,
              let cropped = FrameCrop.centerCrop(cgImage, zoom: zoom)
        else { return nil }
        return UIImage(cgImage: cropped, scale: frame.scale, orientation: frame.imageOrientation)
    }
}

/// A pack JPEG from disk, decoded off the main actor; a bird placeholder when there is none.
struct PackImage: View {
    let url: URL?
    @State private var image: UIImage?

    var body: some View {
        Color.raised
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "bird")
                        .foregroundStyle(Color.inkSecondary)
                }
            }
            .clipped()
            .task(id: url) {
            image = nil
            guard let url else { return }
            image = await Task.detached(priority: .userInitiated) { UIImage(contentsOfFile: url.path(percentEncoded: false)) }.value
        }
    }
}

/// A pack photo with its credit under it: the attributed image. The credit names the observer and the license and
/// opens the observation, so attribution stays next to the picture wherever it appears.
struct AttributedImage: View {
    let pack: SpeciesPack
    let photo: PackPhoto
    var aspectRatio: CGFloat = 3 / 2
    var caption = "Reference photo"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PackImage(url: pack.phoneImageURL(for: photo))
                .aspectRatio(aspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: JournalLayout.cornerRadius, style: .continuous))
                .accessibilityLabel("\(caption): \(photo.creditLine)")
            HStack(alignment: .firstTextBaseline) {
                Text(caption)
                    .font(JournalFont.attribution)
                    .foregroundStyle(Color.inkSecondary)
                Spacer(minLength: 8)
                Link(destination: photo.sourceURL) {
                    HStack(spacing: 3) {
                        Text(photo.shortCredit)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                        Image(systemName: "arrow.up.right")
                            .font(.caption2)
                    }
                    .font(JournalFont.attribution)
                    .foregroundStyle(Color.moss)
                }
                .accessibilityLabel("Photo credit: \(photo.creditLine). Opens the observation on iNaturalist.")
            }
        }
    }
}
