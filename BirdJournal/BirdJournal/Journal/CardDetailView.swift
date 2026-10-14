import Album
import Pack
import SwiftData
import SwiftUI

/// The real flip (issue #52, collectible-cards style guide "Card flip interaction"): the card turns about its vertical
/// centre in about 480 ms with both faces mounted, each face showing only on its half of the turn and never mirrored.
/// With Reduce Motion nothing turns: the faces switch at once.
enum CardFlip {
    static let duration = 0.48

    /// One face at `angle` degrees of the turn (0 front up, 180 back up): how far it is turned and whether it shows.
    static func face(isBack: Bool, angle: Double, rotates: Bool) -> (degrees: Double, isVisible: Bool) {
        let isVisible = isBack ? angle >= 90 : angle < 90
        guard rotates else { return (0, isVisible) }
        return (isBack ? angle - 180 : angle, isVisible)
    }

    /// The turn's animation; none with Reduce Motion.
    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: duration)
    }
}

/// One card, opened from the Cards view (issue #52): the labelled Flip control above the card (so it stays in reach of
/// a card taller than the screen), the persistent two-sided card, and the way to the sighting's full details. The
/// front is the collectible (the art, the place and species, the rarity, the date and method); the back is the
/// encounter story (the time and place, Heard or Seen, the note, the original photo, what the art is and where the
/// rarity came from). Opening a card shows its front.
struct CardDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(PlaceNames.self) private var places
    @Environment(PackLibrary.self) private var library
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Query private var sightings: [Sighting]
    let id: PersistentIdentifier
    @State private var showsBack = false
    @State private var showingOriginal = false
    @State private var isSharing = false
    @AccessibilityFocusState private var flipControlFocused: Bool

    /// Fetched, not `model(for:)`: a deleted id would come back as a placeholder that faults on first access.
    private var sighting: Sighting? {
        var descriptor = FetchDescriptor<Sighting>(predicate: #Predicate { $0.persistentModelID == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private var reduceMotion: Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "reduceMotion") { return true }
        #endif
        return systemReduceMotion
    }

    var body: some View {
        if let sighting {
            let commonName = library.commonName(for: sighting)
            let isLegendary = CardCollection(sightings: sightings).isLegendary(sighting.identifier)
            PaperPage {
                VStack(spacing: JournalLayout.rowGap) {
                    Button(action: flip) {
                        Label(showsBack ? "Flip to artwork" : "Flip to encounter story", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.journalOutlined)
                    .accessibilityValue(showsBack ? "Back" : "Front")
                    .accessibilityIdentifier("card-flip")
                    .accessibilityFocused($flipControlFocused)
                    CollectibleCard(showsBack: showsBack, rotates: !reduceMotion) {
                        CardFront(sighting: sighting, isLegendary: isLegendary, flip: flip)
                    } back: {
                        CardBack(sighting: sighting, isLegendary: isLegendary, showOriginal: { showingOriginal = true })
                    }
                    NavigationLink(value: Route.sighting(id)) {
                        Label("Sighting details", systemImage: "list.bullet.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.journalOutlined)
                }
                .padding(.top, 4)
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
            .sensoryFeedback(.impact(weight: .light), trigger: showsBack)
            .sheet(isPresented: $showingOriginal) {
                if let path = CardText.originalPhotoPath(sighting) {
                    OriginalPhotoView(path: path)
                }
            }
            .sheet(isPresented: $isSharing) {
                SharePostcardView(sighting: sighting)
            }
            .task(id: id) {
                if let location = sighting.location { await places.resolve(location) }
                #if DEBUG
                if UserDefaults.standard.bool(forKey: "autoCardBack") {
                    UserDefaults.standard.removeObject(forKey: "autoCardBack")
                    showsBack = true
                }
                #endif
            }
        } else {
            ContentUnavailableView("Card removed", systemImage: "bird")
        }
    }

    /// Turns the card over and says which face is up. A tap during a turn retargets it, so rapid taps settle on one
    /// face: the state, not the animation, decides which face is readable. VoiceOver's focus goes to the Flip control,
    /// since the art that may have been activated is on the face now hidden.
    private func flip() {
        withAnimation(CardFlip.animation(reduceMotion: reduceMotion)) { showsBack.toggle() }
        flipControlFocused = true
        AccessibilityNotification.Announcement(showsBack ? "Back, encounter story" : "Front, collectible art").post()
    }
}

/// Both faces of one card, stacked so the card keeps the taller face's footprint whichever is up. Only the readable
/// face is exposed to VoiceOver and takes touches.
struct CollectibleCard<Front: View, Back: View>: View {
    let showsBack: Bool
    let rotates: Bool
    @ViewBuilder var front: Front
    @ViewBuilder var back: Back

    var body: some View {
        let angle = showsBack ? 180.0 : 0
        ZStack {
            front
                .modifier(FlipFace(angle: angle, isBack: false, isUp: !showsBack, rotates: rotates))
            back
                .modifier(FlipFace(angle: angle, isBack: true, isUp: showsBack, rotates: rotates))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(rotates ? "card-rotates" : "card-switches")
    }
}

/// One face at a point of the turn, animated through `angle`. Whether it is up comes from the state, not the turn: the
/// face that is up is the one VoiceOver reads and touches reach (`CardFlipAccessibilityTests` walks the tree VoiceOver
/// sees; XCUITest's tree still lists the hidden face, so the UI tests can't check this).
struct FlipFace: ViewModifier, Animatable {
    var angle: Double
    let isBack: Bool
    let isUp: Bool
    let rotates: Bool

    nonisolated var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    func body(content: Content) -> some View {
        let face = CardFlip.face(isBack: isBack, angle: angle, rotates: rotates)
        content
            .accessibilityHidden(!isUp)
            .allowsHitTesting(isUp)
            .rotation3DEffect(.degrees(face.degrees), axis: (x: 0, y: 1, z: 0), perspective: 0.35)
            .opacity(face.isVisible ? 1 : 0)
    }
}

/// The card's frame: gold foil when Legendary, sage otherwise.
private struct CardFrame: ViewModifier {
    let isLegendary: Bool
    let fill: Color

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: CollectibleLayout.cardRadius, style: .continuous)
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(fill, in: shape)
            .overlay {
                shape.strokeBorder(isLegendary ? AnyShapeStyle(.legendaryFoil) : AnyShapeStyle(Color.editionSage), lineWidth: isLegendary ? 5 : 2)
            }
    }
}

/// The collectible face: the Legendary label, the art (a tap flips the card), the place and species, the rarity for
/// that place and season, and the date and method.
private struct CardFront: View {
    @Environment(PackLibrary.self) private var library
    @Environment(PlaceNames.self) private var places
    let sighting: Sighting
    let isLegendary: Bool
    let flip: () -> Void

    var body: some View {
        let reference = library.species(scientificName: sighting.scientificName)
        let commonName = library.commonName(for: sighting)
        VStack(alignment: .leading, spacing: 12) {
            if isLegendary {
                LegendaryLabel()
            }
            Button(action: flip) {
                CardArtView(sighting: sighting, reference: reference, commonName: commonName)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Card art: \(CardArtView.art(for: sighting, reference: reference).label)")
            .accessibilityHint("Flips the card to the encounter story.")
            .accessibilityIdentifier("card-art")
            VStack(alignment: .leading, spacing: 2) {
                Text(places.cardPlace(for: sighting.location))
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.cardIvory.opacity(0.85))
                Text(commonName)
                    .font(JournalFont.title)
                    .foregroundStyle(Color.cardIvory)
                Text(sighting.scientificName)
                    .font(JournalFont.scientific)
                    .foregroundStyle(Color.cardIvory.opacity(0.85))
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            Rectangle().fill(Color.cardIvory.opacity(0.25)).frame(height: 1)
            Label(CardText.rarityLine(sighting.rarity), systemImage: "binoculars")
                .font(JournalFont.supporting.weight(.semibold))
                .foregroundStyle(Color.cardIvory)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(sighting.confirmedAt.formatted(date: .long, time: .omitted)) · \(sighting.method.title)")
                .font(JournalFont.supporting)
                .foregroundStyle(Color.cardIvory.opacity(0.85))
        }
        .padding(14)
        .modifier(CardFrame(isLegendary: isLegendary, fill: .cardFace))
    }
}

/// The encounter story: when and where, Heard or Seen (changed here), the note, the original photo, what the art is
/// and where the rarity came from. Its controls act on their own and never flip the card.
private struct CardBack: View {
    @Environment(PackLibrary.self) private var library
    @Environment(PlaceNames.self) private var places
    @Environment(JournalEdits.self) private var edits
    let sighting: Sighting
    let isLegendary: Bool
    let showOriginal: () -> Void

    var body: some View {
        let reference = library.species(scientificName: sighting.scientificName)
        let method = Binding(get: { sighting.method }, set: { edits.setMethod($0, on: sighting) })
        VStack(alignment: .leading, spacing: 0) {
            Text("Encounter story")
                .font(JournalFont.section)
                .foregroundStyle(Color.ink)
                .accessibilityAddTraits(.isHeader)
            FactRow(label: "When", value: sighting.confirmedAt.formatted(date: .long, time: .shortened))
                .padding(.top, 6)
            RowRule()
            FactRow(label: "Where", value: places.cardPlace(for: sighting.location))
            RowRule()
            Picker("How you met it", selection: method) {
                ForEach(SightingMethod.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.top, 14)
            Text(sighting.method == .heard ? "Every card starts as Heard. Choose Seen if you saw the bird too." : "You saw this bird.")
                .font(JournalFont.attribution)
                .foregroundStyle(Color.inkSecondary)
                .padding(.top, 6)

            BackSection(title: "Your note") {
                Text(sighting.note ?? "No note yet. Add one in Sighting details.")
                    .foregroundStyle(sighting.note == nil ? Color.inkSecondary : Color.ink)
            }
            BackSection(title: "Evidence") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(CardText.evidence(sighting))
                        .foregroundStyle(Color.ink)
                    if CardText.originalPhotoPath(sighting) != nil {
                        Button("View original photo", systemImage: "photo", action: showOriginal)
                            .buttonStyle(.journalOutlined)
                    }
                }
            }
            BackSection(title: "Art") {
                Text(CardArtView.art(for: sighting, reference: reference).provenance)
                    .foregroundStyle(Color.ink)
            }
            BackSection(title: "Rarity") {
                Text(CardText.rarityExplanation(sighting.rarity, commonName: library.commonName(for: sighting), hasLocation: sighting.location != nil))
                    .foregroundStyle(Color.ink)
            }
        }
        .padding(16)
        .modifier(CardFrame(isLegendary: isLegendary, fill: .raised))
    }
}

/// A titled part of the card's back.
private struct BackSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(JournalFont.rowTitle)
                .foregroundStyle(Color.ink)
                .accessibilityAddTraits(.isHeader)
            content
                .font(JournalFont.supporting)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 16)
    }
}

/// The original photo, whole and unaltered: evidence kept with the sighting, never art.
private struct OriginalPhotoView: View {
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
                        ContentUnavailableView("Photo unavailable", systemImage: "photo", description: Text("The file is no longer on this iPhone."))
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
