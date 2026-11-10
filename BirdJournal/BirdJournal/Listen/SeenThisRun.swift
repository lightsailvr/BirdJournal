import Album
import ImageIO
import Pack
import SwiftUI

/// "Seen this run" (issue #186, of #185), above the birds heard: a row for each bird the birder photographed and named on
/// this run, with the photo, the bird's name, and "Seen · your photo · New patch" or its patch's count. No match score: the
/// birder named it. A row opens its sighting.
///
/// #188 adds the photos not yet named to this section, with "Name it".
struct SeenThisRun: View {
    let seen: [RunSightings.Seen]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle("Seen this run", top: 22)
            VStack(spacing: 0) {
                ForEach(seen) { entry in
                    SeenRow(entry: entry)
                    RowRule()
                }
            }
            .padding(.top, 6)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("seen-this-run")
    }
}

private struct SeenRow: View {
    @Environment(PackLibrary.self) private var library
    @Environment(CollectionStore.self) private var collectionStore
    @Environment(\.dynamicTypeSize) private var typeSize
    let entry: RunSightings.Seen

    var body: some View {
        let collection = collectionStore.collection
        let name = library.species(scientificName: entry.scientificName)?.species.commonName ?? entry.commonName
        let parts = NameBirdText.seenRow(sewedPatch: collection.sewedItsPatch(entry.identifier), count: collection.patch(of: entry.identifier)?.count ?? 1)
        NavigationLink(value: Route.sighting(entry.id)) {
            AdaptiveRow(stacked: typeSize.stacksRows) {
                SeenPhoto(path: entry.photoPath)
                    .rowPicture()
                    .clipShape(RoundedRectangle(cornerRadius: JournalLayout.thumbnailRadius, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(JournalFont.rowTitle)
                        .foregroundStyle(Color.ink)
                    Text(NameBirdText.line(parts))
                        .font(JournalFont.supporting)
                        .foregroundStyle(Color.inkSecondary)
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(NameBirdText.sentence([name] + parts))
            .accessibilityHint("Opens the sighting")
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("seen-row-\(entry.scientificName)")
    }
}

/// The birder's photo in a row's slot, filled from the middle. It takes no touches (DECISIONS.md "Clipped images take no
/// touches"), and is read at the slot's size: a camera's picture is twelve megapixels or more.
private struct SeenPhoto: View {
    private static let maxPixels = 360

    @Environment(\.frameStore) private var frameStore
    let path: String?
    @State private var image: UIImage?

    var body: some View {
        Color.raised
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .allowsHitTesting(false)
                } else {
                    Image(systemName: "camera")
                        .foregroundStyle(Color.inkSecondary)
                }
            }
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: path) {
                guard let path, let url = frameStore?.url(for: path) else { return }
                image = await Task.detached(priority: .userInitiated) { Self.fitted(at: url) }.value
            }
    }

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
