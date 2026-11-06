import Album
import Identification
import MapKit
import Pack
import SwiftData
import SwiftUI

/// One sighting in full (issue #28): the glasses snapshot and the reference photo kept apart and labelled, the record
/// (species, when, roughly where, source), Heard or Seen with the caption written for it, the spot on a map card that
/// opens the full map (issue #44), the birder's note, the evidence with their own photo (issue #137), the rarity
/// in words, the explained match, and the way to the bird's profile, to sharing and to a recoverable removal. Since #134
/// the paper card holds the species and the patch's history, and each of its sightings opens here.
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
            PaperPage {
                VStack(alignment: .leading, spacing: 0) {
                    if sighting.frameImagePath != nil {
                        VStack(alignment: .leading, spacing: 6) {
                            FrameImage(frameImagePath: sighting.frameImagePath)
                                .aspectRatio(4 / 3, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: JournalLayout.cornerRadius, style: .continuous))
                                .accessibilityLabel("Your glasses snapshot from this sighting")
                            Text("Your glasses snapshot: the centre of the camera frame when you added the bird. It may show the surroundings rather than the bird.")
                                .font(JournalFont.attribution)
                                .foregroundStyle(Color.inkSecondary)
                        }
                        .padding(.top, 4)
                    }

                    Text(commonName)
                        .font(JournalFont.title)
                        .foregroundStyle(Color.ink)
                        .padding(.top, sighting.frameImagePath != nil ? 18 : 4)
                    Text(sighting.scientificName)
                        .font(JournalFont.scientific)
                        .foregroundStyle(Color.inkSecondary)

                    VStack(spacing: 0) {
                        FactRow(label: "When", value: sighting.confirmedAt.formatted(date: .long, time: .shortened))
                        RowRule()
                        FactRow(label: "Where", value: placeText(for: sighting))
                        RowRule()
                        FactRow(label: "Heard with", value: sighting.source == .glasses ? "Ray-Ban Display" : "iPhone microphone")
                    }
                    .padding(.top, 16)

                    if let location = sighting.location {
                        // The map is a UIKit view underneath and keeps a tap even with hit testing off, so the
                        // control sits over it rather than around it.
                        SightingMapCard(location: location, name: commonName)
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
                            .padding(.top, 12)
                        Text("Where you were when you added the bird. Tap the map to see every sighting.")
                            .font(JournalFont.attribution)
                            .foregroundStyle(Color.inkSecondary)
                            .padding(.top, 6)
                    }

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

                    SectionTitle("Evidence")
                    VStack(alignment: .leading, spacing: 8) {
                        Text(CardText.evidence(sighting))
                            .font(JournalFont.body)
                            .foregroundStyle(Color.ink)
                        if CardText.originalPhotoPath(sighting) != nil {
                            Button("View original photo", systemImage: "photo") { showingOriginal = true }
                                .buttonStyle(.journalOutlined)
                        }
                        SightingPhotos(sighting: sighting)
                    }
                    .padding(.top, 12)

                    if let reference, let photo = reference.species.photos.first {
                        SectionTitle("Reference photo")
                        AttributedImage(pack: reference.pack, photo: photo, caption: "Reference photo, not your bird")
                            .padding(.top, 12)
                    }

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
                    NavigationLink(value: Route.species(scientificName: sighting.scientificName, commonName: commonName)) {
                        Label("Open in Atlas", systemImage: "book")
                    }
                    .buttonStyle(.journalOutlined)
                    .padding(.top, 12)

                    SectionTitle("Rarity")
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
                    .padding(.top, 12)

                    SectionTitle("Identification")
                    SightingMatchDetails(sighting: sighting)
                        .padding(.top, 8)

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

/// The spot on a small map (issue #44): a kilometre across, the moss marker on the fix and a faint circle for its
/// accuracy. Not interactive, and like every picture in the detail it takes no touches (DECISIONS.md "Clipped images
/// take no touches"): the button over it is what opens the full map.
struct SightingMapCard: View {
    let location: Coordinate
    let name: String

    var body: some View {
        let centre = location.clCoordinate
        Map(initialPosition: .region(MKCoordinateRegion(center: centre, latitudinalMeters: 1_000, longitudinalMeters: 1_000)), interactionModes: []) {
            MapCircle(center: centre, radius: max(location.accuracy, 0))
                .foregroundStyle(Color.moss.opacity(0.15))
                .stroke(Color.moss.opacity(0.5), lineWidth: 1)
            Marker(name, coordinate: centre)
                .tint(Color.moss)
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

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label).font(JournalFont.body).foregroundStyle(Color.ink).fixedSize()
                Spacer(minLength: 16)
                Text(value).font(JournalFont.body).foregroundStyle(Color.inkSecondary).multilineTextAlignment(.trailing).fixedSize()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(JournalFont.body).foregroundStyle(Color.ink)
                Text(value).font(JournalFont.body).foregroundStyle(Color.inkSecondary)
            }
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }
}

/// The saved score, in the same disclosure as the live one.
private struct SightingMatchDetails: View {
    let sighting: Sighting
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Model score", value: sighting.soundConfidence.formatted(.number.precision(.fractionLength(2))))
                Text("BirdNET's best single-window score for this species when it was added, between 0 and 1. It is not a calibrated probability, and it does not make the sighting certain: you did, when you added it.")
                    .font(JournalFont.attribution)
                    .foregroundStyle(Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(JournalFont.supporting)
            .padding(.top, 6)
        } label: {
            Label("About this match", systemImage: "waveform.badge.magnifyingglass")
                .font(JournalFont.body)
                .foregroundStyle(Color.ink)
        }
        .tint(Color.moss)
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
