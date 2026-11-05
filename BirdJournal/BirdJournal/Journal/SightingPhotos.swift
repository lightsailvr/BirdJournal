import Album
import ImageIO
import PhotosUI
import SwiftUI

/// The birder's own photo on a sighting (issue #137): attached from the library with the system picker, kept as it came and
/// shown here. It is the sighting's original: "View original photo" and a shared card's original photo use it
/// (`CardText.originalPhotoPath`), and nothing paints it or uploads it. One at a time, so it is clear which one a share
/// sends; a stored sighting with more shows them all.
struct SightingPhotos: View {
    @Environment(JournalEdits.self) private var edits
    let sighting: Sighting
    @State private var pickerItem: PhotosPickerItem?
    @State private var failure: String?
    @State private var removing: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(sighting.attachedPhotoPaths, id: \.self) { path in
                AttachedPhoto(path: path)
                Text("Your photo. It stays on this iPhone unless you choose it when you share this sighting.")
                    .font(JournalFont.attribution)
                    .foregroundStyle(Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Remove photo", systemImage: "trash") { removing = path }
                    .buttonStyle(.journalOutlined)
                    .accessibilityIdentifier("sighting-remove-photo")
            }
            if sighting.attachedPhotoPaths.isEmpty {
                attachButton
            }
            if pickerItem != nil {
                ProgressView("Attaching your photo")
                    .font(JournalFont.supporting)
                    .frame(maxWidth: .infinity)
            }
            if let failure {
                Text(failure)
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.inkSecondary)
                    .accessibilityIdentifier("sighting-photo-failure")
            }
        }
        .task(id: pickerItem) {
            guard let pickerItem else { return }
            let data = try? await pickerItem.loadTransferable(type: Data.self)
            guard !Task.isCancelled else { return }
            attach(data)
            self.pickerItem = nil
        }
        .confirmationDialog(
            "Remove this photo?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible,
            presenting: removing
        ) { path in
            Button("Remove", role: .destructive) { edits.removeAttachedPhoto(path, from: sighting) }
        } message: { _ in
            Text("The copy kept with this sighting goes. The photo in your library stays.")
        }
    }

    private func attach(_ data: Data?) {
        do {
            guard let data else { throw JournalEdits.AttachFailure.unreadable }
            try edits.attachPhoto(data, to: sighting)
            failure = nil
        } catch JournalEdits.AttachFailure.unreadable {
            failure = "That photo couldn't be read. Try another."
        } catch {
            failure = "The photo couldn't be saved on this iPhone."
        }
    }

    private var attachLabel: some View {
        Label("Attach a photo", systemImage: "photo.badge.plus").frame(maxWidth: .infinity)
    }

    @ViewBuilder private var attachButton: some View {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "fakeLibraryPhoto") {
            Button { attach(DebugSeeds.frameJPEG()) } label: { attachLabel }
                .buttonStyle(.journalOutlined)
                .accessibilityIdentifier("sighting-attach-photo")
        } else {
            picker
        }
        #else
        picker
        #endif
    }

    /// Out of process, so it needs no permission to read the library: the app sees only the picture chosen.
    private var picker: some View {
        PhotosPicker(selection: $pickerItem, matching: .images) { attachLabel }
            .buttonStyle(.journalOutlined)
            .accessibilityIdentifier("sighting-attach-photo")
    }
}

/// An attached photo, whole and fitted to the page. It takes no touches (DECISIONS.md "Clipped images take no
/// touches"), and is read at a size for the page, since a library photo can be far larger than the screen.
private struct AttachedPhoto: View {
    private static let maxPixels = 1_200
    /// A portrait photo at full width would take more than the screen.
    private static let maxHeight: CGFloat = 360

    @Environment(\.frameStore) private var frameStore
    let path: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Color.raised.aspectRatio(4 / 3, contentMode: .fit)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: JournalLayout.cornerRadius, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: Self.maxHeight, alignment: .leading)
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel("Your photo")
        .accessibilityAddTraits(.isImage)
        .accessibilityIdentifier("sighting-attached-photo")
        .task(id: path) {
            guard let url = frameStore?.url(for: path) else { return }
            image = await Task.detached(priority: .userInitiated) { Self.fitted(at: url) }.value
        }
    }

    /// The photo turned upright and no larger than `maxPixels` on its longest side.
    nonisolated private static func fitted(at url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(UIImage.init(cgImage:))
    }
}
