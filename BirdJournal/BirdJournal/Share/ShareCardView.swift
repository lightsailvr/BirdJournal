import Album
import CoreTransferable
import ImageIO
import OSLog
import Pack
import SwiftUI
import UniformTypeIdentifiers

/// "A story to share" (issue #66, spec v2 "Shared card"; guide 2.0 page 8): the patch on linen with its paper card as it
/// will be sent, what it carries, and where it goes. The birder chooses the note (off), the city (on; off sends no place)
/// and, for their circles, the original photo (off; faces blurred and metadata stripped on the phone,
/// `SharedPhoto.prepare`) and the circles. **Send** shares the card by hand: the only way a private birder's sighting reaches
/// a circle. **Share card image…** is the system share: the composed image (`PatchShareImage`) as a fresh PNG (no metadata
/// but its pixels) with its text, under the share policy's rules (the city only when chosen and never a coordinate, the
/// note only when chosen).
struct ShareCardView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.frameStore) private var frameStore
    @Environment(PackLibrary.self) private var library
    @Environment(PlaceNames.self) private var places
    @Environment(AccountSession.self) private var account
    @Environment(CircleStore.self) private var circles
    @Environment(FindOutbox.self) private var outbox
    @Environment(CollectionStore.self) private var collectionStore
    let sighting: Sighting
    @State private var choices = FindPolicy.Choices()
    @State private var chosenCircles: Set<String> = []
    @State private var patchLoad = PatchLoad.loading
    @State private var export: CardExport?
    @State private var sending = SendState.idle

    /// The patch's textures for the image: the renderer draws what it's given at once.
    private enum PatchLoad {
        case loading
        /// Nil when the phone has no painting of this patch, or it couldn't be decoded: the image shows the blank.
        case ready(PatchTextures.Loaded?)
    }

    enum SendState: Equatable {
        case idle
        case sending
        case sent(String)
        case failed(String)
    }

    private let log = Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "share")

    private var collection: CardCollection { collectionStore.collection }
    /// Whether this sighting sewed its patch.
    private var sewedPatch: Bool { collection.sewedItsPatch(sighting.identifier) }
    private var input: FindPolicy.Input {
        FindOutbox.input(of: sighting, isNewPatch: outbox.publishedNewPatch(sighting.identifier) ?? sewedPatch, packs: library, places: places)
    }
    private var place: String? { FindPolicy.sharedPlace(for: input, choices: choices) }
    private var hasNote: Bool { !(sighting.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var originalPhotoPath: String? { CardText.originalPhotoPath(sighting) }
    private var showsCircles: Bool { AccountSession.isEnabledInThisBuild && circles.isAvailable }

    private var setID: String? { collection.placement(of: sighting.identifier)?.setID }
    private var patchArt: PatchArt? { library.patchArt(scientificName: sighting.scientificName, setID: setID) }
    /// The species in the pack of the sighting's set, whose patch this is; else in the first pack that has it.
    private var species: PackSpecies? {
        setID.flatMap(library.pack(id:))?.species(scientificName: sighting.scientificName)
            ?? library.species(scientificName: sighting.scientificName)?.species
    }

    /// The share policy's content for the system share: the city (or secret spot) chosen and the note when chosen. No
    /// picture of its own: the composed image is the picture.
    private var content: SharePolicy.Content {
        var policy = SharePolicy.Choices()
        policy.includeNote = choices.includeNote
        policy.useSnapshot = false
        return SharePolicy.content(for: sighting, commonName: library.commonName(for: sighting), reference: nil, area: place, choices: policy)
    }

    private var photoCredits: [String] {
        guard let species, let patch = species.patch, patchArt != nil else { return [] }
        return PatchShareImage.Facts.credits(of: patch, in: species)
    }

    private var facts: PatchShareImage.Facts {
        PatchShareImage.Facts(
            sighting: sighting, name: library.commonName(for: sighting), placement: collection.placement(of: sighting.identifier), place: place,
            lore: species?.lore, hasPainting: patchArt != nil, photoCredits: photoCredits
        )
    }

    private var loaded: PatchTextures.Loaded? {
        if case .ready(let loaded) = patchLoad { loaded } else { nil }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // The rendered face itself, so the preview is exactly the image the system share sends.
                    Group {
                        if let export {
                            Image(uiImage: export.image)
                                .resizable()
                                .scaledToFit()
                        } else {
                            ProgressView().frame(height: 200)
                        }
                    }
                        .frame(maxHeight: 420)
                        .frame(maxWidth: .infinity)
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
            .navigationTitle("Share this patch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(sending.isSent ? "Done" : "Cancel") { dismiss() }
                }
            }
            .scrollEdgeEffectStyle(.hard, for: .bottom)
            .safeAreaBar(edge: .bottom) {
                // Both ways out stay in reach whatever the scroll: Send for the circles, the card image for anywhere.
                VStack(spacing: 8) {
                    sendStatus
                    if canSend {
                        Button {
                            Task { await send() }
                        } label: {
                            Label(sendTitle, systemImage: "paperplane")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.journalPrimary)
                        .disabled(chosenCircles.isEmpty || sending == .sending)
                        .accessibilityIdentifier("share-send")
                    }
                    Group {
                        if let export {
                            ShareLink(item: export, message: Text(export.text), preview: SharePreview(export.title, image: Image(uiImage: export.image))) {
                                Label("Share image", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                            .accessibilityIdentifier("share-system")
                        } else {
                            Label("Preparing the image…", systemImage: "square.and.arrow.up")
                                .foregroundStyle(Color.inkSecondary)
                        }
                    }
                    .buttonStyle(.journalOutlined)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, JournalLayout.margin)
                .padding(.vertical, 12)
            }
            .task(id: patchArt) {
                patchLoad = .loading
                if let patchArt {
                    patchLoad = .ready(await PatchTextures.load(patchArt, size: .full))
                } else {
                    patchLoad = .ready(nil)
                }
            }
            .task(id: ExportKey(choices: choices, place: place, isReady: isReady, hasPatch: loaded != nil)) { render() }
            .task {
                if let location = sighting.location { await places.resolve(location) }
                if showsCircles { await circles.refresh() }
            }
            .onChange(of: choices) { _, _ in if case .failed = sending { sending = .idle } }
        }
    }

    // The circles.

    @ViewBuilder private var circlesSection: some View {
        Text("Your Guilds")
            .font(JournalFont.section)
            .foregroundStyle(Color.ink)
            .padding(.top, JournalLayout.sectionGap)
            .accessibilityAddTraits(.isHeader)
        if !account.isSignedIn {
            Text("Sign in under Settings → Account to share patches with your Guilds.")
                .font(JournalFont.supporting)
                .foregroundStyle(Color.inkSecondary)
                .padding(.top, 8)
        } else if circles.circles.isEmpty {
            Text(circles.listState == .loading ? "Loading your Guilds…" : "You're not in a Guild yet. Start one in the Guilds tab.")
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
                : "Faces are blurred and the location and camera details removed before the photo leaves your iPhone. It goes to your Guilds only, never in the image.")
                .font(JournalFont.attribution)
                .foregroundStyle(Color.inkSecondary)
                .padding(.top, 4)
        }
    }

    /// Signed in with a circle to send to.
    private var canSend: Bool { showsCircles && account.isSignedIn && !circles.circles.isEmpty }

    @ViewBuilder private var sendStatus: some View {
        switch sending {
        case .sent(let message):
            Label(message, systemImage: "checkmark.circle")
                .font(JournalFont.supporting)
                .foregroundStyle(Color.moss)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("share-sent")
        case .failed(let message):
            Text(message)
                .font(JournalFont.supporting)
                .foregroundStyle(Color.alert)
                .accessibilityIdentifier("share-failed")
        case .idle, .sending:
            EmptyView()
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
        case 0: return "Choose a Guild"
        case 1: return "Send to 1 Guild"
        default: return "Send to \(chosenCircles.count) Guilds"
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
            // An automatic find still waiting to go would otherwise reach only the circles chosen here: the server
            // keeps a find's first circles.
            await outbox.flush()
            if outbox.isWaitingToPublish(sighting.identifier) { throw ShareFailure.findWaiting }
            var photo: Data?
            if choices.includeOriginalPhoto {
                guard let path = originalPhotoPath, let url = frameStore?.url(for: path) else { throw ShareFailure.photoUnavailable }
                photo = try await Task.detached(priority: .userInitiated) { try SharedPhoto.prepare(jpeg: Data(contentsOf: url)).jpeg }.value
            }
            try await circles.shareCard(sightingID: sighting.identifier, photo: photo) { key in
                FindPolicy.card(for: input, choices: choices, circleIDs: ids, photoKey: key)
            }
            outbox.sharedByHand(sighting.identifier, isNewPatch: input.isNewPatch)
            sending = .sent("Sent to \(names.formatted(.list(type: .and))).")
        } catch {
            log.error("couldn't share the card: \(String(describing: error))")
            sending = .failed(Self.message(for: error))
        }
    }

    enum ShareFailure: Error {
        case findWaiting
        case photoUnavailable
    }

    static func message(for error: Error) -> String {
        switch error {
        case ShareFailure.findWaiting: "This bird is still on its way to your Guilds. Try again once you're online."
        case ShareFailure.photoUnavailable, is SharedPhoto.Failure: "The original photo couldn't be prepared. Send without it, or try again."
        case CircleError.rejected: "The server turned this down. Try again without the photo."
        default: CircleStore.message(for: error, doing: "share your patch")
        }
    }

    // The face and the system share.

    private var previewLabel: String {
        let name = library.commonName(for: sighting)
        return ["Preview of the image", name, place].compactMap { $0 }.joined(separator: ", ")
    }

    private var placeExplanation: String {
        if sighting.location == nil { return "No location was recorded with this sighting." }
        if !choices.includeCity { return "No place goes with it." }
        if place == FindPolicy.secretSpot { return "This bird is sensitive, so it says \"a secret spot\" instead of a city." }
        if place == nil { return "No city is known for this sighting, so no place goes with it." }
        return "Only the city goes with it, never the exact spot."
    }

    private var isReady: Bool {
        if case .ready = patchLoad { true } else { false }
    }

    /// What the image and its text depend on; the city can arrive after the sheet opens.
    private struct ExportKey: Equatable {
        var choices: FindPolicy.Choices
        var place: String?
        var isReady: Bool
        var hasPatch: Bool
    }

    /// Renders the image into a PNG with nothing but its pixels, once the patch is decoded.
    @MainActor
    private func render() {
        guard isReady else { return }
        let image = PatchShareImage(facts: facts, edition: PatchEdition.of(setID: setID), loaded: loaded)
        guard let rendered = CardExport.render(image, scale: CardExport.imageScale) else { return }
        let content = content
        let lore = species?.lore
        let credits = photoCredits.isEmpty ? nil : "Patch: AI illustration from a reference photo (\(photoCredits.joined(separator: "; ")))"
        let text = [SharePolicy.text(for: content), credits, lore.map(Self.loreCredit)].compactMap { $0 }.joined(separator: "\n")
        export = CardExport(image: rendered.image, png: rendered.png, text: text, title: "\(content.commonName) · Featherguild")
    }

    /// The credit of the lore the image takes its story title from (issue #116; design guide page 17: lore licenses and
    /// revision links travel with shared exports): who wrote it, its sources and license, and the article revision.
    static func loreCredit(_ lore: PackLore) -> String {
        (["Lore: \(LoreText.credit(lore))"] + [lore.wikipediaRevision?.absoluteString].compactMap { $0 }).joined(separator: " ")
    }
}

extension ShareCardView.SendState {
    var isSent: Bool { if case .sent = self { true } else { false } }
}

/// The share image as the system share takes it: the image, a fresh PNG of it, and the text.
struct CardExport: Transferable {
    let image: UIImage
    let png: Data
    let text: String
    let title: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { export in export.png }
            .suggestedFileName { "\($0.title).png" }
    }

    /// The scale of the share image, whatever the phone's screen: `PatchShareImage` draws its patch 240 points wide, so
    /// the patch comes to 1080 px (guide page 8).
    static let imageScale: CGFloat = 4.5

    /// The view drawn 360 points wide, and its PNG.
    @MainActor
    static func render(_ view: some View, scale: CGFloat) -> (image: UIImage, png: Data)? {
        let renderer = ImageRenderer(content: view.frame(width: 360))
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
