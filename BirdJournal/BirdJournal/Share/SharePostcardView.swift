import Album
import CoreTransferable
import ImageIO
import Pack
import SwiftUI
import UniformTypeIdentifiers

/// Sharing a sighting (issue #28): a postcard preview, the fields to include, the promise about location, then the
/// native share sheet with the rendered card and its text. The export is a fresh PNG: no location and no camera
/// metadata ever ride along.
struct SharePostcardView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @Environment(\.frameStore) private var frameStore
    @Environment(PackLibrary.self) private var library
    @Environment(PlaceNames.self) private var places
    let sighting: Sighting
    @State private var choices = SharePolicy.Choices()
    @State private var export: PostcardExport?
    @State private var isRendering = false

    private var content: SharePolicy.Content {
        let reference = library.species(scientificName: sighting.scientificName)
        return SharePolicy.content(
            for: sighting,
            commonName: library.commonName(for: sighting),
            reference: reference?.species.photos.first,
            area: sighting.location.flatMap(places.name(for:)),
            choices: choices
        )
    }

    private var referencePack: SpeciesPack? { library.species(scientificName: sighting.scientificName)?.pack }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PostcardView(content: content, pack: referencePack, frameStore: frameStore)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                        .accessibilityLabel("Preview of the card")

                    Text("Include in your card")
                        .font(JournalFont.section)
                        .foregroundStyle(Color.ink)
                        .padding(.top, JournalLayout.sectionGap)
                        .accessibilityAddTraits(.isHeader)
                    VStack(spacing: 0) {
                        Toggle(isOn: $choices.includeDate) { Label("Date", systemImage: "calendar") }
                            .padding(.vertical, 10)
                        RowRule()
                        Toggle(isOn: $choices.includeArea) { Label("General area", systemImage: "mappin.and.ellipse") }
                            .padding(.vertical, 10)
                            .disabled(sighting.location.flatMap(places.name(for:)) == nil)
                        RowRule()
                        Toggle(isOn: $choices.includeNote) { Label("Personal note", systemImage: "note.text") }
                            .padding(.vertical, 10)
                            .disabled((sighting.note ?? "").isEmpty)
                        if sighting.frameImagePath != nil {
                            RowRule()
                            Toggle(isOn: $choices.useSnapshot) { Label("My glasses snapshot", systemImage: "eyeglasses") }
                                .padding(.vertical, 10)
                        }
                    }
                    .tint(Color.moss)
                    .font(JournalFont.body)
                    .foregroundStyle(Color.ink)
                    .padding(.top, 8)

                    Label(areaExplanation, systemImage: "checkmark.shield")
                        .font(JournalFont.supporting)
                        .foregroundStyle(Color.inkSecondary)
                        .padding(.top, 16)
                    if case .reference(let photo) = content.picture {
                        Text("The reference photo is by \(photo.observer) (\(photo.license)); its credit and link go with the card.")
                            .font(JournalFont.attribution)
                            .foregroundStyle(Color.inkSecondary)
                            .padding(.top, 8)
                    } else if case .none = content.picture, sighting.frameImagePath == nil {
                        Text("No photo can be shared for this bird, so the card carries the words alone.")
                            .font(JournalFont.attribution)
                            .foregroundStyle(Color.inkSecondary)
                            .padding(.top, 8)
                    }
                }
                .padding(.horizontal, JournalLayout.margin)
                .padding(.bottom, JournalLayout.sectionGap)
            }
            .background(Color.paper)
            .navigationTitle("Share a sighting")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Group {
                    if let export {
                        ShareLink(item: export, message: Text(export.text), preview: SharePreview(export.title, image: Image(uiImage: export.image))) {
                            Label("Share…", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.journalPrimary)
                    } else {
                        Button {
                            render()
                        } label: {
                            Label(isRendering ? "Preparing…" : "Share…", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.journalPrimary)
                        .disabled(isRendering)
                    }
                }
                .padding(.horizontal, JournalLayout.margin)
                .padding(.vertical, 12)
                .background(.bar)
            }
            .onChange(of: choices) { _, _ in export = nil }
        }
    }

    private var areaExplanation: String {
        if sighting.location == nil { return "No location was recorded with this sighting." }
        if sighting.location.flatMap(places.name(for:)) == nil { return "The exact location is hidden; no place name is known to share." }
        return "Exact location is hidden. Only the general area is shared, if you include it."
    }

    /// Renders the card at the screen's scale into a PNG with no metadata but its pixels.
    @MainActor
    private func render() {
        isRendering = true
        let renderer = ImageRenderer(content: PostcardView(content: content, pack: referencePack, frameStore: frameStore).frame(width: 360))
        renderer.scale = max(displayScale, 2)
        renderer.proposedSize = ProposedViewSize(width: 360, height: nil)
        guard let image = renderer.uiImage, let cgImage = image.cgImage, let png = PostcardExport.png(cgImage) else {
            isRendering = false
            return
        }
        export = PostcardExport(image: image, png: png, text: SharePolicy.text(for: content), title: "\(content.commonName) · Bird Journal")
        isRendering = false
    }
}

extension PostcardExport {
    /// The card's pixels as a PNG through ImageIO with no properties: the file carries its dimensions and colour
    /// chunks and nothing else (no Exif date, TIFF orientation, GPS or maker notes), whatever the source image knew.
    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

/// The rendered card and its text, as the share sheet takes them.
struct PostcardExport: Transferable {
    let image: UIImage
    let png: Data
    let text: String
    let title: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { export in export.png }
            .suggestedFileName { "\($0.title).png" }
    }
}

/// The card's colours, fixed rather than the catalog's tokens: the export is the same picture in every appearance.
enum PostcardPalette {
    static let paper = Color(red: 0.973, green: 0.961, blue: 0.929)
    static let raised = Color(red: 0.906, green: 0.929, blue: 0.875)
    static let ink = Color(red: 0.15, green: 0.20, blue: 0.16)
    static let secondary = Color(red: 0.36, green: 0.40, blue: 0.37)
    static let rule = Color(red: 0.85, green: 0.87, blue: 0.82)
}

/// The postcard itself: warm paper, the picture, "A small discovery", the name, the date and area, the note, and the
/// caption with the credit. Drawn on screen and rendered for the export from the same view.
struct PostcardView: View {
    let content: SharePolicy.Content
    let pack: SpeciesPack?
    let frameStore: FrameStore?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            picture
                .aspectRatio(3 / 2, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text("A small discovery")
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .tracking(2)
                .foregroundStyle(PostcardPalette.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 18)
            Text(content.commonName)
                .font(.system(size: 30, design: .serif))
                .foregroundStyle(PostcardPalette.ink)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
            Text(content.scientificName)
                .font(.system(size: 14, design: .serif).italic())
                .foregroundStyle(PostcardPalette.secondary)
                .frame(maxWidth: .infinity)
            if let line = [content.dateText, content.areaText].compactMap({ $0 }).joined(separator: " · ").nilIfEmpty {
                Text(line)
                    .font(.system(size: 15))
                    .foregroundStyle(PostcardPalette.ink)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
            }
            if let note = content.note {
                Text("“\(note)”")
                    .font(.system(size: 14, design: .serif).italic())
                    .foregroundStyle(PostcardPalette.ink)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)
            }
            Text(content.pictureCaption)
                .font(.system(size: 11))
                .foregroundStyle(PostcardPalette.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 14)
        }
        .padding(16)
        .background(PostcardPalette.paper, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(PostcardPalette.rule, lineWidth: 1))
        .environment(\.colorScheme, .light)
    }

    @ViewBuilder
    private var picture: some View {
        switch content.picture {
        case .snapshot(let framePath):
            PostcardFrame(url: frameStore?.url(for: framePath))
        case .reference(let photo):
            PostcardPackImage(url: pack?.phoneImageURL(for: photo))
        case .none:
            ZStack {
                PostcardPalette.raised
                PerchedBirdDrawing().frame(height: 90)
            }
        }
    }
}

/// Synchronous images for the card, so the renderer has the pixels when it draws.
private struct PostcardPackImage: View {
    let url: URL?

    var body: some View {
        PostcardPalette.raised
            .overlay {
                if let url, let image = UIImage(contentsOfFile: url.path(percentEncoded: false)) {
                    Image(uiImage: image).resizable().scaledToFill().allowsHitTesting(false)
                }
            }
            .clipped()
    }
}

private struct PostcardFrame: View {
    let url: URL?

    var body: some View {
        PostcardPalette.raised
            .overlay {
                if let url, let image = FrameImage.croppedFrame(at: url, zoom: 2) {
                    Image(uiImage: image).resizable().scaledToFill().allowsHitTesting(false)
                }
            }
            .clipped()
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
