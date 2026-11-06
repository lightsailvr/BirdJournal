import Album
import Identification
import MapKit
import Pack
import SwiftData
import SwiftUI

/// One sighting as a record (issue #150, A6, from #28): it leads with your original photo where there is one, else its patch. When,
/// where and how sit on a paper record. Heard or Seen, the caption written for it, the spot on a map card that opens the full map
/// (issue #44), your note and your photos (issue #137) stay in view. The rest is a bird's page and a tap away: a reference photo
/// kept apart and labelled, and the rarity and the explained match in disclosures. Sharing is in the toolbar, and a removal is
/// confirmed and recoverable. Since #134 the paper card holds the species and the patch's history, and each of its sightings opens here.
struct SightingDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(PlaceNames.self) private var places
    @Environment(PackLibrary.self) private var library
    @Environment(CollectionStore.self) private var collectionStore
    @Environment(JournalEdits.self) private var edits
    let id: PersistentIdentifier
    @State private var note = ""
    @State private var isSharing = false
    @State private var showingMap = false
    @State private var confirmingRemoval = false
    @State private var showingOriginal = false
    @FocusState private var editingNote: Bool

    /// Fetched, not `model(for:)`: a deleted id would come back as a placeholder that faults on first access.
    private var sighting: Sighting? {
        var descriptor = FetchDescriptor<Sighting>(predicate: #Predicate { $0.persistentModelID == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// What removing the sighting does to its patch (issue #132): the last sighting of the bird in its place unpicks
    /// the patch, and the dialog says so; otherwise the patch keeps the others.
    private func removalMessage(for sighting: Sighting, commonName: String) -> String {
        let collection = collectionStore.collection
        guard collection.isLastSighting(of: sighting.identifier), let patch = collection.patch(of: sighting.identifier) else {
            return "Its patch keeps your other sightings. You can undo this for a few seconds afterwards."
        }
        let place = patch.placement.setID == nil ? "outside every set" : "in \(patch.placement.setName)"
        return "It's your only \(commonName) sighting \(place), so its patch will be unpicked. You can undo this for a few seconds afterwards."
    }

    var body: some View {
        if let sighting {
            let reference = library.species(scientificName: sighting.scientificName)
            let commonName = library.commonName(for: sighting)
            let patch = collectionStore.collection.patch(of: sighting.identifier)
            let leadPhoto = sighting.attachedPhotoPaths.first
            ScrollViewReader { proxy in
            PaperPage {
                VStack(alignment: .leading, spacing: 0) {
                    RecordLead(sighting: sighting, patch: patch, name: commonName)
                        .padding(.top, 4)
                        .padding(.bottom, 16)

                    SightingRecord(name: commonName, sighting: sighting, place: placeText(for: sighting))

                    Picker("How you met it", selection: Binding(get: { sighting.method }, set: { edits.setMethod($0, on: sighting) })) {
                        ForEach(SightingMethod.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.top, 16)
                    Text(sighting.method == .heard ? "Choose Seen if you saw the bird too." : "You saw this bird.")
                        .font(JournalFont.attribution)
                        .foregroundStyle(Color.inkSecondary)
                        .padding(.top, 6)
                    if let caption = sighting.caption?.text.nilIfEmpty {
                        Text(caption)
                            .font(CardFont.lore)
                            .lineSpacing(CardFont.loreLeading)
                            .foregroundStyle(Color.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 12)
                            .accessibilityLabel("Caption: \(caption)")
                            .accessibilityIdentifier("card-caption")
                    }

                    if let location = sighting.location {
                        // The map is a UIKit view underneath and keeps a tap even with hit testing off, so the
                        // control sits over it rather than around it.
                        SightingMapCard(location: location, name: commonName, setID: patch?.placement.setID)
                            .overlay {
                                Button {
                                    showingMap = true
                                } label: {
                                    Color.clear.contentShape(RoundedRectangle(cornerRadius: JournalLayout.cornerRadius, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Map of where you heard this bird. Opens every sighting on a map.")
                                .accessibilityIdentifier("sighting-map-card")
                            }
                            .padding(.top, 16)
                        Text("Where you were when you added the bird. Tap the map to see every sighting.")
                            .font(JournalFont.attribution)
                            .foregroundStyle(Color.inkSecondary)
                            .padding(.top, 6)
                    }

                    SectionTitle("Your note")
                    TextField("Add a note", text: $note, axis: .vertical)
                        .font(JournalFont.body)
                        .foregroundStyle(Color.ink)
                        .lineLimit(2...8)
                        .padding(14)
                        .background(Color.raised, in: RoundedRectangle(cornerRadius: JournalLayout.cornerRadius, style: .continuous))
                        .focused($editingNote)
                        .padding(.top, 12)
                        .onChange(of: editingNote) { _, editing in
                            if !editing { edits.setNote(note, on: sighting) }
                        }
                        .accessibilityLabel("Your note")

                    SectionTitle("Your photos")
                    VStack(alignment: .leading, spacing: 8) {
                        if CardText.originalPhotoPath(sighting) != nil {
                            Button("View original photo", systemImage: "photo") { showingOriginal = true }
                                .buttonStyle(.journalOutlined)
                        }
                        SightingPhotos(sighting: sighting, leadPath: leadPhoto)
                    }
                    .padding(.top, 12)

                    SectionTitle("About this bird")
                    if let summary = reference?.species.summary, !summary.isEmpty {
                        Text(summary)
                            .font(JournalFont.body)
                            .foregroundStyle(Color.ink)
                            .padding(.top, 12)
                    } else if reference == nil {
                        Text("No photos or notes for this bird are in your field-guide downloads. It was identified by name.")
                            .font(JournalFont.body)
                            .foregroundStyle(Color.inkSecondary)
                            .padding(.top, 12)
                    }
                    if let reference, let photo = reference.species.photos.first {
                        AttributedImage(pack: reference.pack, photo: photo, caption: "Reference photo, not your bird")
                            .padding(.top, 12)
                    }
                    NavigationLink(value: Route.species(scientificName: sighting.scientificName, commonName: commonName)) {
                        Label("Open in Atlas", systemImage: "book")
                    }
                    .buttonStyle(.journalOutlined)
                    .padding(.top, 12)

                    VStack(spacing: 0) {
                        RecordDisclosure("Rarity", identifier: "record-rarity") {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(CardText.rarityLine(sighting.rarity))
                                    .font(JournalFont.supporting.weight(.semibold))
                                    .foregroundStyle(Color.ink)
                                    .accessibilityIdentifier("card-rarity")
                                Text(CardText.rarityExplanation(sighting.rarity, commonName: commonName, hasLocation: sighting.location != nil))
                                    .font(JournalFont.supporting)
                                    .foregroundStyle(Color.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        RowRule()
                        RecordDisclosure("Identification", identifier: "record-identification") {
                            SightingMatchDetails(sighting: sighting)
                        }
                    }
                    .padding(.top, JournalLayout.sectionGap)
                    .id("record-disclosures")

                    Button(role: .destructive) {
                        confirmingRemoval = true
                    } label: {
                        Label("Remove from collection", systemImage: "trash")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.alert)
                    .padding(.top, JournalLayout.sectionGap)
                }
            }
            #if DEBUG
            .debugScroll(proxy, to: "record-disclosures")
            #endif
            }
            // A sighting's page is in its patch's edition, like the patch's own.
            .tint(patch.map { PatchEdition.tint(setID: $0.placement.setID) })
            .navigationTitle(commonName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isSharing = true
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .sheet(isPresented: $isSharing) {
                ShareCardView(sighting: sighting)
            }
            .sheet(isPresented: $showingMap) {
                SightingMapView(focus: sighting)
            }
            .sheet(isPresented: $showingOriginal) {
                if let path = CardText.originalPhotoPath(sighting) {
                    OriginalPhotoView(path: path)
                }
            }
            .confirmationDialog("Remove this sighting?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    edits.remove(sighting, commonName: commonName)
                    dismiss()
                }
            } message: {
                Text(removalMessage(for: sighting, commonName: commonName))
            }
            .task(id: id) {
                note = sighting.note ?? ""
                if let location = sighting.location { await places.resolve(location) }
                #if DEBUG
                if UserDefaults.standard.bool(forKey: "autoShare") {
                    UserDefaults.standard.removeObject(forKey: "autoShare")
                    try? await Task.sleep(for: .milliseconds(600))
                    isSharing = true
                }
                if UserDefaults.standard.bool(forKey: "autoMap") {
                    UserDefaults.standard.removeObject(forKey: "autoMap")
                    try? await Task.sleep(for: .milliseconds(600))
                    showingMap = true
                }
                #endif
            }
            .onDisappear {
                if let sighting = self.sighting { edits.setNote(note, on: sighting) }
            }
        } else {
            StateNotice("Sighting removed", mark: .symbol("bird"))
                .statePage()
        }
    }

    /// The approximate place: the name when known, else the coordinate to two decimals (about a kilometre).
    private func placeText(for sighting: Sighting) -> String {
        guard let location = sighting.location else { return "No location was recorded" }
        return places.name(for: location).map { "Near \($0)" } ?? "Near \(location.formatted)"
    }
}

/// What a record leads with: your original photo where there is one, since it's evidence, else its patch on felt, which opens the
/// patch's page. A sighting always has a patch, but one that's just gone from the collection shows nothing here.
private struct RecordLead: View {
    @Environment(PackLibrary.self) private var library
    let sighting: Sighting
    let patch: CardCollection.Patch?
    let name: String

    var body: some View {
        if let path = sighting.attachedPhotoPaths.first {
            AttachedPhoto(path: path)
                .frame(maxWidth: .infinity)
        } else if sighting.frameImagePath != nil {
            VStack(alignment: .leading, spacing: 6) {
                FrameImage(frameImagePath: sighting.frameImagePath)
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: JournalLayout.cornerRadius, style: .continuous))
                    .accessibilityLabel("Your glasses snapshot from this sighting")
                    .accessibilityIdentifier("record-photo")
                Text("Your glasses snapshot: the centre of the camera frame when you added the bird. It may show the surroundings rather than the bird.")
                    .font(JournalFont.attribution)
                    .foregroundStyle(Color.inkSecondary)
            }
        } else if let patch {
            let state = library.patchArtState(scientificName: patch.scientificName, setID: patch.placement.setID)
            FeltBoard {
                NavigationLink(value: Route.patch(patch.id)) {
                    PatchView(state: state, edition: PatchEdition.of(setID: patch.placement.setID), size: .full, tag: name)
                        .frame(width: 190)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(PatchText.spoken(patch, name: name, beingSewn: state == .beingSewn))
                .accessibilityHint("Opens the patch")
                .accessibilityIdentifier("record-patch")
                .frame(maxWidth: .infinity)
            }
            .clipShape(RoundedRectangle(cornerRadius: JournalLayout.cornerRadius, style: .continuous))
            .holdsPatchLight()
        }
    }
}

/// When, where and how, printed: the rule's "if you read it, it's printed on paper".
private struct SightingRecord: View {
    let name: String
    let sighting: Sighting
    let place: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(name)
                .font(CardFont.birdName)
                .foregroundStyle(Color.cardInk)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(sighting.scientificName)
                .font(CardFont.scientific)
                .foregroundStyle(Color.cardInkSecondary)
                .padding(.bottom, 8)
            FactRow(label: "When", value: sighting.confirmedAt.formatted(date: .long, time: .shortened), ink: .cardInk, secondary: .cardInkSecondary)
            PaperRule()
            FactRow(label: "Where", value: place, ink: .cardInk, secondary: .cardInkSecondary)
            PaperRule()
            FactRow(label: "How", value: CardText.how(sighting), ink: .cardInk, secondary: .cardInkSecondary)
        }
        .padding(.top, 28)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CardStockSurface())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sighting-record")
    }
}

/// Something a record keeps until you ask for it. VoiceOver hears a button that says whether it's open.
private struct RecordDisclosure<Content: View>: View {
    let title: String
    let identifier: String
    @ViewBuilder var content: Content
    @State private var isExpanded: Bool

    init(_ title: String, identifier: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.identifier = identifier
        self.content = content()
        #if DEBUG
        // `-autoRecordOpen YES`, for the screenshots.
        _isExpanded = State(initialValue: UserDefaults.standard.bool(forKey: "autoRecordOpen"))
        #else
        _isExpanded = State(initialValue: false)
        #endif
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
                .padding(.bottom, 12)
        } label: {
            Text(title)
                .font(JournalFont.heading)
                .foregroundStyle(Color.ink)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
                .accessibilityIdentifier(identifier)
        }
    }
}

/// The spot on a small map (issue #44): a kilometre across, a marker on the fix in the place's tint (issue #150) and a faint circle
/// for its accuracy. Not interactive, and like every picture in the detail it takes no touches (DECISIONS.md "Clipped images
/// take no touches"): the button over it is what opens the full map.
struct SightingMapCard: View {
    let location: Coordinate
    let name: String
    /// The patch's set, nil for Uncharted.
    let setID: String?

    var body: some View {
        let centre = location.clCoordinate
        let tint = PatchEdition.tint(setID: setID)
        Map(initialPosition: .region(MKCoordinateRegion(center: centre, latitudinalMeters: 1_000, longitudinalMeters: 1_000)), interactionModes: []) {
            MapCircle(center: centre, radius: max(location.accuracy, 0))
                .foregroundStyle(tint.opacity(0.15))
                .stroke(tint.opacity(0.5), lineWidth: 1)
            Marker(name, coordinate: centre)
                .tint(tint)
        }
        .mapStyle(.standard)
        .mapControlVisibility(.hidden)
        .aspectRatio(16 / 10, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: JournalLayout.cornerRadius, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A label and a value on one line, wrapping when the value is long.
struct FactRow: View {
    let label: String
    let value: String
    var ink = Color.ink
    var secondary = Color.inkSecondary

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label).font(JournalFont.body).foregroundStyle(ink).fixedSize()
                Spacer(minLength: 16)
                Text(value).font(JournalFont.body).foregroundStyle(secondary).multilineTextAlignment(.trailing).fixedSize()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(JournalFont.body).foregroundStyle(ink)
                Text(value).font(JournalFont.body).foregroundStyle(secondary)
            }
        }
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The saved score, explained, and whether there's a photo to go with it.
private struct SightingMatchDetails: View {
    let sighting: Sighting

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Model score", value: sighting.soundConfidence.formatted(.number.precision(.fractionLength(2))))
            Text("BirdNET's best single-window score for this species when it was added, between 0 and 1. It is not a calibrated probability, and it does not make the sighting certain: you did, when you added it.")
                .font(JournalFont.attribution)
                .foregroundStyle(Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent("Evidence", value: CardText.evidence(sighting))
        }
        .font(JournalFont.supporting)
    }
}

/// The original photo, whole and unaltered: evidence kept with the sighting, never art.
struct OriginalPhotoView: View {
    @Environment(\.frameStore) private var frameStore
    @Environment(\.dismiss) private var dismiss
    let path: String
    @State private var image: UIImage?
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            PaperPage {
                VStack(alignment: .leading, spacing: 8) {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: JournalLayout.cornerRadius, style: .continuous))
                            .accessibilityLabel("Original photo")
                    } else if loaded {
                        StateNotice("Photo unavailable", message: "The file is no longer on this iPhone.", mark: .symbol("photo"))
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 200)
                    }
                    Text("The unaltered photo kept with this sighting: evidence, never art.")
                        .font(JournalFont.attribution)
                        .foregroundStyle(Color.inkSecondary)
                }
                .padding(.top, 4)
            }
            .navigationTitle("Original photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: path) {
                if let url = frameStore?.url(for: path) {
                    image = await Task.detached(priority: .userInitiated) { (try? Data(contentsOf: url)).flatMap(UIImage.init(data:)) }.value
                }
                loaded = true
            }
        }
    }
}
