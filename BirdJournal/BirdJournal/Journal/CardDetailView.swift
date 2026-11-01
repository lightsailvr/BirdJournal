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
///
/// Above the card, "3 of 15" with Previous and Next (issue #53): within the gallery's filter and sort when the card
/// was opened from a gallery, else among all the species' cards newest first. Each opens that card in place, front
/// up; at either end the unavailable direction is disabled. All encounters goes back to the gallery, or opens one.
struct CardDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(PlaceNames.self) private var places
    @Environment(PackLibrary.self) private var library
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.dismiss) private var dismiss
    @Query private var sightings: [Sighting]
    /// The gallery this card was opened from, nil from anywhere else.
    let browse: GalleryBrowse?
    /// The card shown: the one opened, until Previous or Next opens another.
    @State private var id: PersistentIdentifier
    @State private var showsBack = false
    @State private var showingOriginal = false
    @State private var isSharing = false
    @AccessibilityFocusState private var flipControlFocused: Bool

    init(id: PersistentIdentifier, browse: GalleryBrowse? = nil) {
        self.browse = browse
        _id = State(initialValue: id)
    }

    /// Fetched, not `model(for:)`: a deleted id would come back as a placeholder that faults on first access.
    private var sighting: Sighting? {
        let id = id
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
            let collection = library.collection(of: sightings)
            let isLegendary = collection.isLegendary(sighting.identifier)
            let placement = collection.placement(of: sighting.identifier)
            let gallery = (browse ?? GalleryBrowse(scientificName: sighting.scientificName)).gallery(sightings, places: places)
            PaperPage {
                VStack(spacing: JournalLayout.rowGap) {
                    if let position = gallery.position(of: sighting.identifier) {
                        CardStepper(position: position, previous: gallery.previous(of: sighting.identifier), next: gallery.next(of: sighting.identifier), open: open)
                    }
                    Button(action: flip) {
                        Label(showsBack ? "Flip to artwork" : "Flip to encounter story", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.journalOutlined)
                    .accessibilityValue(showsBack ? "Back" : "Front")
                    .accessibilityIdentifier("card-flip")
                    .accessibilityFocused($flipControlFocused)
                    CollectibleCard(showsBack: showsBack, rotates: !reduceMotion) {
                        CardFront(sighting: sighting, isLegendary: isLegendary, placement: placement, flip: flip)
                    } back: {
                        CardBack(sighting: sighting, isLegendary: isLegendary, showOriginal: { showingOriginal = true })
                    }
                    if browse != nil {
                        Button {
                            dismiss()
                        } label: {
                            AllEncountersLabel()
                        }
                        .buttonStyle(.journalOutlined)
                        .accessibilityIdentifier("card-all-encounters")
                    } else {
                        NavigationLink(value: Route.gallery(scientificName: sighting.scientificName, commonName: commonName, selected: sighting.identifier)) {
                            AllEncountersLabel()
                        }
                        .buttonStyle(.journalOutlined)
                        .accessibilityIdentifier("card-all-encounters")
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
                browse?.selected = sighting.identifier
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

    /// Opens another card of the gallery in place, front up: a different card is a different object, not a turn.
    private func open(_ identifier: UUID) {
        guard let target = sightings.first(where: { $0.identifier == identifier }) else { return }
        showsBack = false
        id = target.persistentModelID
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

/// The way from a card to its species' gallery.
private struct AllEncountersLabel: View {
    var body: some View {
        Label("All encounters", systemImage: "square.grid.2x2")
            .frame(maxWidth: .infinity)
    }
}

/// "3 of 15" between Previous and Next; at either end the unavailable direction is disabled. At accessibility text
/// sizes the buttons keep only their chevrons, so the position keeps its room.
private struct CardStepper: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let position: SpeciesGallery.Position
    let previous: UUID?
    let next: UUID?
    let open: (UUID) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button {
                if let previous { open(previous) }
            } label: {
                Label("Previous", systemImage: "chevron.left")
                    .labelStyle(StepperLabelStyle(iconOnly: typeSize.isAccessibilitySize, iconTrailing: false))
            }
            .disabled(previous == nil)
            .accessibilityLabel("Previous card")
            .accessibilityIdentifier("card-previous")
            Text(position.text)
                .font(JournalFont.supporting.weight(.semibold))
                .foregroundStyle(Color.ink)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Card \(position.index) of \(position.count)")
                .accessibilityIdentifier("card-position")
            Button {
                if let next { open(next) }
            } label: {
                Label("Next", systemImage: "chevron.right")
                    .labelStyle(StepperLabelStyle(iconOnly: typeSize.isAccessibilitySize, iconTrailing: true))
            }
            .disabled(next == nil)
            .accessibilityLabel("Next card")
            .accessibilityIdentifier("card-next")
        }
        .buttonStyle(.journalOutlined)
    }
}

/// A stepper button's label: the chevron on the side it points to, alone at accessibility text sizes.
private struct StepperLabelStyle: LabelStyle {
    let iconOnly: Bool
    let iconTrailing: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            if !iconTrailing { configuration.icon }
            if !iconOnly { configuration.title }
            if iconTrailing { configuration.icon }
        }
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

/// The collectible face: the Legendary label or the edition with the collector number, the art (a tap flips the card),
/// the place and species, the type line and stats (issue #55), the rarity for that place and season, and the date and
/// method.
private struct CardFront: View {
    @Environment(PackLibrary.self) private var library
    @Environment(PlaceNames.self) private var places
    let sighting: Sighting
    let isLegendary: Bool
    let placement: CardPlacement?
    let flip: () -> Void

    var body: some View {
        let reference = library.species(scientificName: sighting.scientificName)
        let commonName = library.commonName(for: sighting)
        VStack(alignment: .leading, spacing: 12) {
            CardHeading(isLegendary: isLegendary, placement: placement)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(CardHeading.accessibilityText(isLegendary: isLegendary, placement: placement).compactMap { $0 }.joined(separator: ", "))
                .accessibilityIdentifier("card-heading")
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
            if let typeLine = reference?.species.typeLine {
                Text(typeLine.text)
                    .font(JournalFont.supporting.weight(.semibold))
                    .foregroundStyle(Color.cardIvory)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Type: \(typeLine.groupWord), \(typeLine.familyWord)")
                    .accessibilityIdentifier("card-type-line")
            }
            if let stats = reference?.species.stats.map({ CardStatsText.front($0) }), !stats.isEmpty {
                FrontStats(stats: stats)
            }
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

/// The front's wingspan, weight and diet, side by side, or stacked when they don't fit (accessibility text sizes). Each
/// reads as one VoiceOver element: "Wingspan about 9 inches, estimated from wing length", "Diet: mostly seeds".
private struct FrontStats: View {
    let stats: [CardStatsText.Stat]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) { cells }
            VStack(alignment: .leading, spacing: 8) { cells }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("card-stats")
    }

    private var cells: some View {
        ForEach(stats, id: \.label) { stat in
            VStack(alignment: .leading, spacing: 2) {
                Text(stat.label)
                    .font(JournalFont.attribution)
                    .foregroundStyle(Color.cardIvory.opacity(0.85))
                HStack(spacing: 4) {
                    if let symbol = stat.symbol {
                        Image(systemName: symbol)
                    }
                    Text(stat.value)
                }
                .font(JournalFont.supporting.weight(.semibold))
                .foregroundStyle(Color.cardIvory)
            }
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(stat.spoken)
            .accessibilityIdentifier("card-stat-\(stat.label.lowercased())")
        }
    }
}

/// The encounter story: when and where, Heard or Seen (changed here), the note, the original photo, what the art is,
/// where the rarity came from, and the species' natural history (issue #55). Its controls act on their own and never
/// flip the card.
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
            BackSection(title: "Natural history") {
                if let stats = reference?.species.stats {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(CardStatsText.back(stats).enumerated()), id: \.element.label) { index, stat in
                            if index > 0 { RowRule() }
                            FactRow(label: stat.label, value: stat.value)
                        }
                        Text(CardStatsText.sources(stats))
                            .font(JournalFont.attribution)
                            .foregroundStyle(Color.inkSecondary)
                            .padding(.top, 8)
                    }
                    .accessibilityIdentifier("card-natural-history")
                } else {
                    Text("No natural-history stats for this bird in your packs.")
                        .foregroundStyle(Color.inkSecondary)
                }
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
