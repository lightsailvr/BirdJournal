import Album
import CoreTransferable
import ImageIO
import OSLog
import Pack
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// "A story to share" (issue #66, spec v2 "Shared card"): the card's face as it will be sent, what it carries, and
/// where it goes. The birder chooses the note (off), the city (on; off sends no place) and, for their circles, the
/// original photo (off; faces blurred and metadata stripped on the phone, `ArtPhoto.prepare`) and the circles. **Send**
/// shares the card by hand: the only way a private birder's sighting reaches a circle. **Share card image…** is the
/// system share: the card face as a fresh PNG (no metadata but its pixels) with its text, under the share policy's
/// rules (the city only when chosen and never a coordinate, the note only when chosen, a pack photo only when its
/// license allows, with its credit).
struct ShareCardView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @Environment(\.frameStore) private var frameStore
    @Environment(PackLibrary.self) private var library
    @Environment(PlaceNames.self) private var places
    @Environment(AccountSession.self) private var account
    @Environment(CircleStore.self) private var circles
    @Environment(FindOutbox.self) private var outbox
    @Query private var sightings: [Sighting]
    let sighting: Sighting
    @State private var choices = FindPolicy.Choices()
    @State private var chosenCircles: Set<String> = []
    @State private var artImage: UIImage?
    @State private var export: CardExport?
    @State private var sending = SendState.idle

    enum SendState: Equatable {
        case idle
        case sending
        case sent(String)
        case failed(String)
    }

    private let log = Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "share")

    private var collection: CardCollection { library.collection(of: sightings) }
    private var isLegendary: Bool { collection.isLegendary(sighting.identifier) }
    private var input: FindPolicy.Input {
        FindOutbox.input(of: sighting, isLegendary: outbox.publishedLegendary(sighting.identifier) ?? isLegendary, packs: library, places: places)
    }
    private var place: String? { FindPolicy.sharedPlace(for: input, choices: choices) }
    private var hasNote: Bool { !(sighting.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var originalPhotoPath: String? { CardText.originalPhotoPath(sighting) }
    private var showsCircles: Bool { AccountSession.isEnabledInThisBuild && circles.isAvailable }

    /// The share policy's content for the system share: the city (or secret spot) chosen, the note when chosen, and
    /// whether the species' pack photo may travel, with its credit. Never the glasses snapshot: the card face is the
    /// picture now.
    private var content: SharePolicy.Content {
        var policy = SharePolicy.Choices()
        policy.includeNote = choices.includeNote
        policy.useSnapshot = false
        return SharePolicy.content(
            for: sighting, commonName: library.commonName(for: sighting),
            reference: library.species(scientificName: sighting.scientificName)?.species.photos.first,
            area: place, choices: policy
        )
    }

    /// The face's art: the card's own, except a pack photo whose license doesn't allow a share, which gives way to the
    /// typographic face.
    private var faceArt: CardText.Art {
        Self.faceArt(CardArtView.art(for: sighting, library: library, setID: collection.placement(of: sighting.identifier)?.setID), content: content)
    }

    static func faceArt(_ art: CardText.Art, content: SharePolicy.Content) -> CardText.Art {
        if case .referencePhoto = art, case .reference = content.picture { return art }
        if case .referencePhoto = art { return .none }
        return art
    }

    private var face: some View {
        CardFront(
            sighting: sighting, isLegendary: isLegendary, placement: collection.placement(of: sighting.identifier), place: place,
            art: faceArt, artImage: artImage
        )
        .environment(library)
        .environment(\.colorScheme, .light)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    face
                        .frame(maxWidth: 360)
                        .frame(maxWidth: .infinity)
                        .allowsHitTesting(false)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(previewLabel)
                        .accessibilityIdentifier("share-preview")
                        .padding(.top, 4)

                    Text("Include")
                        .font(JournalFont.section)
                        .foregroundStyle(Color.ink)
                        .padding(.top, JournalLayout.sectionGap)
                        .accessibilityAddTraits(.isHeader)
                    VStack(spacing: 0) {
                        Toggle(isOn: $choices.includeNote) { Label("Your note", systemImage: "note.text") }
                            .padding(.vertical, 10)
                            .disabled(!hasNote)
                            .accessibilityIdentifier("share-note")
                        RowRule()
                        Toggle(isOn: $choices.includeCity) { Label("City", systemImage: "building.2") }
                            .padding(.vertical, 10)
                            .accessibilityIdentifier("share-city")
                    }
                    .tint(Color.moss)
                    .font(JournalFont.body)
                    .foregroundStyle(Color.ink)
                    .padding(.top, 8)
                    Label(placeExplanation, systemImage: "checkmark.shield")
                        .font(JournalFont.supporting)
                        .foregroundStyle(Color.inkSecondary)
                        .padding(.top, 8)
                        .accessibilityIdentifier("share-place-explanation")

                    if showsCircles {
                        circlesSection
                    }
                }
                .padding(.horizontal, JournalLayout.margin)
                .padding(.bottom, JournalLayout.sectionGap)
            }
            .background(Color.paper)
            .navigationTitle("A story to share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(sending.isSent ? "Done" : "Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Group {
                    if let export {
                        ShareLink(item: export, message: Text(export.text), preview: SharePreview(export.title, image: Image(uiImage: export.image))) {
                            Label("Share card image…", systemImage: "square.and.arrow.up")
                        }
                        .accessibilityIdentifier("share-system")
                    } else {
                        Label("Preparing the card…", systemImage: "square.and.arrow.up")
                            .foregroundStyle(Color.inkSecondary)
                    }
                }
                .buttonStyle(.journalOutlined)
                .padding(.horizontal, JournalLayout.margin)
                .padding(.vertical, 12)
                .background(.bar)
            }
            .task(id: faceArt) { loadArt() }
            .task(id: ExportKey(choices: choices, hasArt: artImage != nil)) { render() }
            .task {
                if let location = sighting.location { await places.resolve(location) }
                if showsCircles { await circles.refresh() }
            }
            .onChange(of: choices) { _, _ in if case .failed = sending { sending = .idle } }
        }
    }

    // The circles.

    @ViewBuilder private var circlesSection: some View {
        Text("Your circles")
            .font(JournalFont.section)
            .foregroundStyle(Color.ink)
            .padding(.top, JournalLayout.sectionGap)
            .accessibilityAddTraits(.isHeader)
        if !account.isSignedIn {
            Text("Sign in under Settings → Account to share cards with your circles.")
                .font(JournalFont.supporting)
                .foregroundStyle(Color.inkSecondary)
                .padding(.top, 8)
        } else if circles.circles.isEmpty {
            Text(circles.listState == .loading ? "Loading your circles…" : "You're not in a circle yet. Start one in the Circles tab.")
                .font(JournalFont.supporting)
                .foregroundStyle(Color.inkSecondary)
                .padding(.top, 8)
                .accessibilityIdentifier("share-no-circles")
        } else {
            VStack(spacing: 0) {
                ForEach(Array(circles.circles.enumerated()), id: \.element.id) { index, circle in
                    if index > 0 { RowRule() }
                    Toggle(isOn: chosen(circle.id)) { Label(circle.name, systemImage: "person.3") }
                        .padding(.vertical, 10)
                        .accessibilityIdentifier("share-circle-\(circle.name)")
                }
                RowRule()
                Toggle(isOn: $choices.includeOriginalPhoto) { Label("Original photo", systemImage: "photo") }
                    .padding(.vertical, 10)
                    .disabled(originalPhotoPath == nil)
                    .accessibilityIdentifier("share-photo")
            }
            .tint(Color.moss)
            .font(JournalFont.body)
            .foregroundStyle(Color.ink)
            .padding(.top, 8)
            Text(originalPhotoPath == nil
                ? "No original photo with this sighting."
                : "Faces are blurred and the location and camera details removed before the photo leaves your iPhone. It goes to your circles only, never in the card image.")
                .font(JournalFont.attribution)
                .foregroundStyle(Color.inkSecondary)
                .padding(.top, 4)
            Button {
                Task { await send() }
            } label: {
                Label(sendTitle, systemImage: "paperplane")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.journalPrimary)
            .disabled(chosenCircles.isEmpty || sending == .sending)
            .padding(.top, 14)
            .accessibilityIdentifier("share-send")
            switch sending {
            case .sent(let message):
                Label(message, systemImage: "checkmark.circle")
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.moss)
                    .padding(.top, 8)
                    .accessibilityIdentifier("share-sent")
            case .failed(let message):
                Text(message)
                    .font(JournalFont.supporting)
                    .foregroundStyle(.red)
                    .padding(.top, 8)
                    .accessibilityIdentifier("share-failed")
            case .idle, .sending:
                EmptyView()
            }
        }
    }

    private func chosen(_ id: String) -> Binding<Bool> {
        Binding(
            get: { chosenCircles.contains(id) },
            set: { isOn in
                if isOn { chosenCircles.insert(id) } else { chosenCircles.remove(id) }
                if case .failed = sending { sending = .idle }
            }
        )
    }

    private var sendTitle: String {
        if sending == .sending { return "Sending…" }
        switch chosenCircles.count {
        case 0: return "Choose a circle"
        case 1: return "Send to 1 circle"
        default: return "Send to \(chosenCircles.count) circles"
        }
    }

    /// Shares the card by hand: the photo prepared (faces blurred, metadata stripped) and uploaded when chosen, then
    /// the card, and the outbox told, so a later Heard-to-Seen or a removal reaches it.
    private func send() async {
        sending = .sending
        let ids = circles.circles.map(\.id).filter(chosenCircles.contains)
        let names = circles.circles.filter { chosenCircles.contains($0.id) }.map(\.name)
        let input = input
        let choices = choices
        do {
            var photo: Data?
            if choices.includeOriginalPhoto, let path = originalPhotoPath, let url = frameStore?.url(for: path) {
                photo = try await Task.detached(priority: .userInitiated) { try ArtPhoto.prepare(jpeg: Data(contentsOf: url)).jpeg }.value
            }
            try await circles.shareCard(sightingID: sighting.identifier, photo: photo) { key in
                FindPolicy.card(for: input, choices: choices, circleIDs: ids, photoKey: key)
            }
            outbox.sharedByHand(sighting.identifier, isLegendary: input.isLegendary)
            sending = .sent("Sent to \(names.formatted(.list(type: .and))).")
        } catch {
            log.error("couldn't share the card: \(String(describing: error))")
            sending = .failed(CircleStore.message(for: error, doing: "share your card"))
        }
    }

    // The face and the system share.

    private var previewLabel: String {
        let name = library.commonName(for: sighting)
        return ["Preview of the card", name, place].compactMap { $0 }.joined(separator: ", ")
    }

    private var placeExplanation: String {
        if sighting.location == nil { return "No location was recorded with this sighting." }
        if !choices.includeCity { return "No place goes with the card." }
        if place == FindPolicy.secretSpot { return "This bird is sensitive, so the card says \"a secret spot\" instead of a city." }
        if place == nil { return "No city is known for this sighting, so no place goes with the card." }
        return "Only the city goes with the card, never the exact spot."
    }

    /// The face's picture, loaded before the face is rendered: the renderer draws what is there at once.
    private func loadArt() {
        switch faceArt {
        case .photoArt(let path), .sceneArt(let path):
            artImage = (frameStore?.url(for: path)).flatMap { FrameImage.croppedFrame(at: $0, zoom: 1) }
        case .packArt(let url, _), .referencePhoto(let url, _):
            artImage = UIImage(contentsOfFile: url.path(percentEncoded: false))
        case .none:
            artImage = nil
        }
    }

    private struct ExportKey: Equatable {
        var choices: FindPolicy.Choices
        var hasArt: Bool
    }

    /// Renders the face at the screen's scale into a PNG with nothing but its pixels.
    @MainActor
    private func render() {
        export = nil
        guard let image = CardExport.render(face, scale: max(displayScale, 2)) else { return }
        let content = content
        export = CardExport(image: image.image, png: image.png, text: SharePolicy.text(for: content), title: "\(content.commonName) · Bird Journal")
    }
}

extension ShareCardView.SendState {
    var isSent: Bool { if case .sent = self { true } else { false } }
}

/// The card face as the system share takes it: the image, a fresh PNG of it, and the text.
struct CardExport: Transferable {
    let image: UIImage
    let png: Data
    let text: String
    let title: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { export in export.png }
            .suggestedFileName { "\($0.title).png" }
    }

    /// The face drawn 360 points wide, and its PNG.
    @MainActor
    static func render(_ face: some View, scale: CGFloat) -> (image: UIImage, png: Data)? {
        let renderer = ImageRenderer(content: face.frame(width: 360))
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(width: 360, height: nil)
        guard let image = renderer.uiImage, let cgImage = image.cgImage, let png = png(cgImage) else { return nil }
        return (image, png)
    }

    /// The pixels as a PNG through ImageIO with no properties: the file carries its dimensions and colour chunks and
    /// nothing else (no Exif date, TIFF orientation, GPS or maker notes), whatever the art's source file knew.
    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
