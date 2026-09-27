import Album
import Pack
import SwiftData
import SwiftUI

/// The album on the phone (issue #11, spec user stories 35 and 37): every saved sighting, newest first, with the
/// 2x center crop of the frame the glasses kept, the species, the date and the place.
struct AlbumView: View {
    @Query(Sighting.newestFirst()) private var sightings: [Sighting]

    var body: some View {
        Group {
            if sightings.isEmpty {
                ContentUnavailableView(
                    "No sightings yet",
                    systemImage: "bird",
                    description: Text("Birds you add to your list from the glasses appear here.")
                )
            } else {
                List(sightings) { sighting in
                    NavigationLink(value: ContentView.Screen.sighting(id: sighting.persistentModelID)) {
                        SightingRow(sighting: sighting)
                    }
                }
            }
        }
        .navigationTitle("Album")
    }
}

/// One sighting: the cropped frame, the species, when and where.
private struct SightingRow: View {
    @Environment(PlaceNames.self) private var places
    let sighting: Sighting

    var body: some View {
        HStack(spacing: 12) {
            FrameThumbnail(frameImagePath: sighting.frameImagePath)
                .frame(width: 72, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(BundledPack.commonName(for: sighting))
                Text(sighting.confirmedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(places.placeText(for: sighting.location))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .task(id: sighting.location) {
            if let location = sighting.location { await places.resolve(location) }
        }
    }
}

/// One sighting in full: the crop across the screen, then the record.
struct SightingDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(PlaceNames.self) private var places
    let id: PersistentIdentifier

    /// Fetched, not `model(for:)`: a deleted id would come back as a placeholder that faults on first access.
    private var sighting: Sighting? {
        var descriptor = FetchDescriptor<Sighting>(predicate: #Predicate { $0.persistentModelID == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    var body: some View {
        if let sighting {
            List {
                Section {
                    FrameThumbnail(frameImagePath: sighting.frameImagePath)
                        .aspectRatio(4 / 3, contentMode: .fit)
                        .listRowInsets(EdgeInsets())
                } footer: {
                    Text(sighting.frameImagePath == nil ? "No camera frame was kept with this sighting." : "The center of the last camera frame, 2x.")
                }
                Section {
                    LabeledContent("Species", value: BundledPack.commonName(for: sighting))
                    LabeledContent("Scientific name", value: sighting.scientificName)
                    LabeledContent("When", value: sighting.confirmedAt.formatted(date: .long, time: .shortened))
                    LabeledContent("Where", value: placeText(for: sighting))
                    LabeledContent("Match", value: sighting.soundConfidence.formatted(.percent.precision(.fractionLength(0))))
                    LabeledContent("Heard with", value: sighting.source == .glasses ? "Glasses" : "Phone")
                }
            }
            .navigationTitle(BundledPack.commonName(for: sighting))
            .navigationBarTitleDisplayMode(.inline)
            .task(id: sighting.location) {
                if let location = sighting.location { await places.resolve(location) }
            }
        } else {
            ContentUnavailableView("Sighting removed", systemImage: "bird")
        }
    }

    /// The place line with the coordinate beside a known name, since the detail has room for both.
    private func placeText(for sighting: Sighting) -> String {
        guard let location = sighting.location, places.name(for: location) != nil else { return places.placeText(for: sighting.location) }
        return "\(places.placeText(for: location)) (\(location.formatted))"
    }
}

/// The 2x center crop of a stored frame, decoded off the main actor; a placeholder while it loads or when the file
/// is gone (iOS can purge frames that fell back to tmp).
private struct FrameThumbnail: View {
    @Environment(\.frameStore) private var frameStore
    let frameImagePath: String?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(.secondarySystemFill)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "camera")
                    .foregroundStyle(.secondary)
            }
        }
        .clipped()
        .task(id: frameImagePath) {
            image = nil
            guard let frameImagePath, let url = frameStore?.url(for: frameImagePath) else { return }
            image = await Task.detached(priority: .userInitiated) { Self.croppedFrame(at: url) }.value
        }
    }

    /// The frame at `url` cropped to its center at the album's zoom, keeping the JPEG's orientation. Read as data,
    /// not by path: `URL.path()` percent-encodes the space in "Application Support".
    nonisolated static func croppedFrame(at url: URL) -> UIImage? {
        guard let data = try? Data(contentsOf: url), let frame = UIImage(data: data), let cgImage = frame.cgImage,
              let cropped = FrameCrop.centerCrop(cgImage)
        else { return nil }
        return UIImage(cgImage: cropped, scale: frame.scale, orientation: frame.imageOrientation)
    }
}
