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
/// front tells the story (issue #116: the painting, the names, the lore excerpt and a quiet footer); the back holds
/// the encounter, the note, the full lore, the natural history, the evidence, the rarity and the art's sources.
/// Opening a card shows its front.
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
                        CardFront(sighting: sighting, placement: placement, place: places.cardPlace(for: sighting.location), flip: flip)
                    } back: {
                        CardBack(sighting: sighting, placement: placement, showOriginal: { showingOriginal = true })
                    }
                    CardArtActions(sighting: sighting)
                    PhotoArtActions(sighting: sighting)
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
            // The card and its reading area get the whole height (design guide page 10); back returns to the tabs.
            .toolbar(.hidden, for: .tabBar)
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
                ShareCardView(sighting: sighting)
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

/// Scene art's controls under the card (issue #68, spec v2 stories 50 and 52): Try again and Use pack art on a card
/// with a painting, Use painted art to go back to it, Retry art and Keep current art after a failure, and Paint this
/// scene on a glasses card never painted (the public launch's ordinary adds, issue #69), with "N left today". Asking for a new
/// painting needs the account (`ArtJobs.isAvailable`); choosing between the painting and the pack art doesn't. A card
/// whose job is pending polls it while it is open.
private struct CardArtActions: View {
    @Environment(ArtJobs.self) private var art
    let sighting: Sighting
    @State private var asking = false

    var body: some View {
        let status = sighting.art.sceneStatus
        Group {
            switch status {
            case .ready(let showsPackArt):
                HStack(spacing: 10) {
                    if art.isAvailable {
                        Button("Try again", systemImage: "arrow.clockwise") { paintAgain() }
                            .accessibilityHint("Paints a new picture. This one stays until the new one is ready.")
                            .accessibilityIdentifier("card-art-try-again")
                    }
                    if showsPackArt {
                        Button("Use painted art", systemImage: "photo.artframe") { art.setShowsPackArt(false, on: sighting) }
                            .accessibilityIdentifier("card-art-use-painted")
                    } else {
                        Button("Use pack art", systemImage: "square.stack") { art.setShowsPackArt(true, on: sighting) }
                            .accessibilityIdentifier("card-art-use-pack")
                    }
                }
            case .failed:
                HStack(spacing: 10) {
                    if art.isAvailable {
                        Button("Retry art", systemImage: "arrow.clockwise") { paintAgain() }
                            .accessibilityIdentifier("card-art-retry")
                    }
                    Button("Keep current art", systemImage: "checkmark") { art.keepCurrentArt(sighting) }
                        .accessibilityIdentifier("card-art-keep")
                }
            case .none:
                // At the public launch an ordinary add isn't painted automatically: scene art is the birder's to ask
                // for, within the day's allowance (issue #69). A card that was never painted (signed out at the add)
                // gets the same.
                if art.isAvailable, sighting.frameImagePath != nil {
                    Button {
                        paintAgain()
                    } label: {
                        Label("Paint this scene", systemImage: "paintbrush.pointed").frame(maxWidth: .infinity)
                    }
                    .accessibilityHint("Paints the bird into your glasses photo.")
                    .accessibilityIdentifier("card-art-paint")
                }
            case .pending:
                EmptyView()
            }
        }
        .buttonStyle(.journalOutlined)
        .safeAreaInset(edge: .bottom, spacing: 4) {
            if let refusal = art.refusal(for: sighting, kind: .scene) {
                Text(refusal)
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("card-art-refusal")
            }
            // "N left today" beside the buttons that spend one (issue #69); nothing in the friends phase.
            if art.isAvailable, status != .pending, sighting.frameImagePath != nil || status != .none, let line = CardText.allowanceLine(art.allowance) {
                Text(line)
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("card-art-allowance")
            }
        }
        .task { await art.refreshAllowance() }
        .disabled(asking)
        .task(id: sighting.art.pendingJobs.map(\.id)) {
            // While this card waits, look in on its jobs now and then: the painting machine may come back any time.
            while !Task.isCancelled, !sighting.art.pendingJobs.isEmpty {
                await art.refresh(sighting)
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func paintAgain() {
        asking = true
        Task {
            await art.paintAgain(sighting)
            asking = false
        }
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

/// Both faces of one card, stacked into one footprint: the front's (issue #116). The story-first front sets the card's
/// size; the back, which holds much more (the full lore, the natural history, the evidence), takes the same size and
/// scrolls inside it, so the turn keeps a stable footprint and the front has no empty space under its footer. Only the
/// readable face is exposed to VoiceOver and takes touches.
struct CollectibleCard<Front: View, Back: View>: View {
    let showsBack: Bool
    let rotates: Bool
    @ViewBuilder var front: Front
    @ViewBuilder var back: Back
    @State private var frontHeight: CGFloat?

    var body: some View {
        let angle = showsBack ? 180.0 : 0
        ZStack(alignment: .top) {
            front
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { frontHeight = $0 }
                .modifier(FlipFace(angle: angle, isBack: false, isUp: !showsBack, rotates: rotates))
            // Zero until the front is measured: the back's scroll view would otherwise take its whole content's height.
            back
                .frame(height: frontHeight ?? 0)
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
            // A container first (issue #119): `.accessibilityHidden(false)` straight on the face that is up re-exposed the
            // decorations inside it that hide themselves (the edge, the keyline, the sprigs, the fine rules), as empty
            // VoiceOver stops. As a container the face keeps their hiding and still hides whole when it isn't up.
            .accessibilityElement(children: .contain)
            .accessibilityHidden(!isUp)
            .allowsHitTesting(isUp)
            .rotation3DEffect(.degrees(face.degrees), axis: (x: 0, y: 1, z: 0), perspective: 0.35)
            .opacity(face.isVisible ? 1 : 0)
    }
}

/// The story-first front (issue #116, design guide page 5, the reference card): the edition, the
/// bird's name upright and its scientific name in italics, the painting (a tap flips the card) with its compact credit,
/// then the tale: the story title when the pack has an approved one (#113), and an excerpt of the approved lore in a true italic
/// serif (`LoreExcerpt`: whole sentences, about 25–40 words). Without a title the excerpt leads; without lore the tale
/// is left out. Then the quiet footer: the place, the date and Heard or Seen, the rarity in words, and the collector
/// number. The stats, the type line and the caption are on the back. Nothing is clipped or shrunk: at large text sizes
/// the card grows. The share sheet (issue #66) draws the same face with the place it may share (a city, a secret spot
/// or none) and the art already loaded, so the renderer has the pixels when it draws.
struct CardFront: View {
    @Environment(PackLibrary.self) private var library
    let sighting: Sighting
    let placement: CardPlacement?
    /// The place line: the card's place on the phone; on a shared face, only what the share may carry.
    let place: String?
    /// The story title in place of the pack's (#113: `PackLore.title`, 2–5 reviewed words); nil reads the pack's, and
    /// without one the excerpt leads. The app never invents one.
    var storyTitle: String? = nil
    /// The art to draw, in place of what `CardArtView.art` gives; nil draws that.
    var art: CardText.Art? = nil
    /// The art's picture, loaded already (the share's renderer can't wait for it).
    var artImage: UIImage? = nil
    var flip: () -> Void = {}

    var body: some View {
        let reference = library.species(scientificName: sighting.scientificName)
        let art = art ?? CardArtView.art(for: sighting, library: library, setID: placement?.setID)
        let commonName = library.commonName(for: sighting)
        let excerpt = reference?.species.lore.flatMap { LoreExcerpt.front($0.text) }
        let storyTitle = self.storyTitle ?? reference?.species.lore?.title?.nilIfEmpty
        let heading = CardHeading.accessibilityText(placement: placement)
        VStack(spacing: 12) {
            CardHeading(placement: placement)
                .padding(.horizontal, 24)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(heading.first.flatMap { $0 } ?? "")
                .accessibilityIdentifier("card-heading")
            VStack(spacing: 2) {
                Text(commonName)
                    .font(CardFont.birdName)
                    .foregroundStyle(Color.cardInk)
                Text(sighting.scientificName)
                    .font(CardFont.scientific)
                    .foregroundStyle(Color.cardInkSecondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("card-name")
            Button(action: flip) {
                CardArtView(art: art, commonName: commonName, image: artImage)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Card art: \(art.label)")
            .accessibilityHint("Flips the card to the encounter story.")
            .accessibilityIdentifier("card-art")
            if let line = CardText.sceneArtLine(sighting.art.sceneStatus) {
                Label(line, systemImage: sighting.art.sceneStatus == .failed ? "exclamationmark.circle" : "paintbrush.pointed")
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.cardInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(line)
                    .accessibilityIdentifier("card-art-status")
            }
            if storyTitle != nil || excerpt != nil {
                VStack(spacing: 8) {
                    if let storyTitle {
                        Text(storyTitle)
                            .font(CardFont.storyTitle)
                            .foregroundStyle(Color.cardInk)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("card-story-title")
                        Rectangle()
                            .fill(Color.cardEdge.opacity(0.35))
                            .frame(width: 72, height: 1)
                            .accessibilityHidden(true)
                    }
                    if let excerpt {
                        Text(excerpt)
                            .font(CardFont.lore)
                            .lineSpacing(CardFont.loreLeading)
                            .foregroundStyle(Color.cardInk)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("card-lore-excerpt")
                    }
                }
                .padding(.top, 2)
            }
            Rectangle().fill(Color.cardEdge.opacity(0.3)).frame(height: 1).accessibilityHidden(true)
            CardFooter(
                line: CardFooter.line(place: place, date: sighting.confirmedAt, method: sighting.method),
                rarity: CardText.rarityLine(sighting.rarity),
                number: CardHeading.numberText(placement: placement),
                numberLabel: heading.count > 1 ? heading.last.flatMap { $0 } : nil
            )
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .modifier(CardSurface())
    }
}

/// The species' wingspan, weight and diet, side by side, or stacked when they don't fit (accessibility text sizes).
/// Each reads as one VoiceOver element: "Wingspan about 9 inches, estimated from wing length", "Diet: mostly seeds".
private struct CardStats: View {
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
                    .foregroundStyle(Color.cardInkSecondary)
                HStack(spacing: 4) {
                    if let symbol = stat.symbol {
                        Image(systemName: symbol)
                    }
                    Text(stat.value)
                }
                .font(JournalFont.supporting.weight(.semibold))
                .foregroundStyle(Color.cardInk)
            }
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(stat.spoken)
            .accessibilityIdentifier("card-stat-\(stat.label.lowercased())")
        }
    }
}

/// The reverse (design guide pages 7 and 15, "A deeper reverse"): the encounter first (when and where, Heard or Seen,
/// changed here, and the caption written for this sighting, issue #56), then the birder's note, the species' full lore
/// with its tagline and credit, its natural history (the type line and stats of #55, then habitat to lifestyle), the
/// evidence (the original photo), the rarity in words and where it came from, and what the art is with its sources.
/// The sighting, the species and the evidence stay in separate sections. It scrolls inside the front's footprint
/// (`CollectibleCard`). Its controls act on their own and never flip the card.
struct CardBack: View {
    @Environment(PackLibrary.self) private var library
    @Environment(PlaceNames.self) private var places
    @Environment(JournalEdits.self) private var edits
    let sighting: Sighting
    let placement: CardPlacement?
    let showOriginal: () -> Void

    var body: some View {
        let reference = library.species(scientificName: sighting.scientificName)
        let method = Binding(get: { sighting.method }, set: { edits.setMethod($0, on: sighting) })
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Encounter story")
                    .font(JournalFont.section)
                    .foregroundStyle(Color.cardInk)
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
                    .foregroundStyle(Color.cardInkSecondary)
                    .padding(.top, 6)
                if let caption = sighting.caption?.text.nilIfEmpty {
                    Text(caption)
                        .font(CardFont.lore)
                        .lineSpacing(CardFont.loreLeading)
                        .foregroundStyle(Color.cardInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                        .accessibilityLabel("Caption: \(caption)")
                        .accessibilityIdentifier("card-caption")
                }

                BackSection(title: "Your note") {
                    Text(sighting.note ?? "No note yet. Add one in Sighting details.")
                        .foregroundStyle(sighting.note == nil ? Color.cardInkSecondary : Color.cardInk)
                }
                BackSection(title: "Lore") {
                    if let lore = reference?.species.lore {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(lore.tagline)
                                .font(CardFont.lore)
                                .foregroundStyle(Color.cardInk)
                                .accessibilityLabel("Tagline: \(lore.tagline)")
                                .accessibilityIdentifier("card-tagline")
                            Text(lore.text)
                                .font(.system(.callout, design: .serif))
                                .lineSpacing(3)
                                .foregroundStyle(Color.cardInk)
                            Text(LoreText.credit(lore))
                                .font(JournalFont.attribution)
                                .foregroundStyle(Color.cardInkSecondary)
                            if let revision = lore.wikipediaRevision {
                                Link("Wikipedia article revision", destination: revision)
                                    .font(JournalFont.attribution)
                                    .foregroundStyle(Color.cardEdge)
                            }
                        }
                        .accessibilityIdentifier("card-lore")
                    } else {
                        Text("No lore for this bird in your packs yet.")
                            .foregroundStyle(Color.cardInkSecondary)
                    }
                }
                BackSection(title: "Natural history") {
                    if let typeLine = reference?.species.typeLine {
                        Text(typeLine.text)
                            .font(JournalFont.supporting.weight(.semibold))
                            .foregroundStyle(Color.cardInk)
                            .accessibilityLabel("Type: \(typeLine.groupWord), \(typeLine.familyWord)")
                            .accessibilityIdentifier("card-type-line")
                            .padding(.bottom, 6)
                    }
                    if let stats = reference?.species.stats {
                        VStack(alignment: .leading, spacing: 0) {
                            let front = CardStatsText.front(stats)
                            if !front.isEmpty {
                                CardStats(stats: front)
                                    .padding(.vertical, 6)
                                RowRule()
                            }
                            ForEach(Array(CardStatsText.back(stats).enumerated()), id: \.element.label) { index, stat in
                                if index > 0 { RowRule() }
                                FactRow(label: stat.label, value: stat.value)
                            }
                            Text(CardStatsText.sources(stats))
                                .font(JournalFont.attribution)
                                .foregroundStyle(Color.cardInkSecondary)
                                .padding(.top, 8)
                        }
                        .accessibilityIdentifier("card-natural-history")
                    } else {
                        Text("No natural-history stats for this bird in your packs.")
                            .foregroundStyle(Color.cardInkSecondary)
                    }
                }
                BackSection(title: "Evidence") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(CardText.evidence(sighting))
                            .foregroundStyle(Color.cardInk)
                        if CardText.originalPhotoPath(sighting) != nil {
                            Button("View original photo", systemImage: "photo", action: showOriginal)
                                .buttonStyle(.journalOutlined)
                        }
                    }
                }
                BackSection(title: "Rarity") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(CardText.rarityLine(sighting.rarity))
                            .font(JournalFont.supporting.weight(.semibold))
                            .foregroundStyle(Color.cardInk)
                        Text(CardText.rarityExplanation(sighting.rarity, commonName: library.commonName(for: sighting), hasLocation: sighting.location != nil))
                            .foregroundStyle(Color.cardInk)
                    }
                }
                BackSection(title: "Art and sources") {
                    Text(CardArtView.art(for: sighting, library: library, setID: placement?.setID).provenance)
                        .foregroundStyle(Color.cardInk)
                }
            }
            .padding(20)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.visible)
        .clipShape(RoundedRectangle(cornerRadius: CollectibleLayout.cardRadius, style: .continuous))
        .accessibilityIdentifier("card-back-scroll")
        .modifier(CardSurface(sprigs: nil))
    }
}

/// A titled part of the card's back.
private struct BackSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(JournalFont.heading)
                .foregroundStyle(Color.cardInk)
                .accessibilityAddTraits(.isHeader)
            content
                .font(JournalFont.supporting)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 20)
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
