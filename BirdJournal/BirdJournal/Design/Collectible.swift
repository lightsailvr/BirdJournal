import Album
import NaturalLanguage
import Pack
import SwiftUI

/// The collectible cards' tokens (issue #116, Featherguild design guide pages 5–9). A card is an ivory object in both
/// appearances, the same anatomy on every species: teal ink, a teal outer edge with a fine inner keyline, and a gold
/// perimeter only on a Legendary card (the personal first; gold never marks rarity, which is said in words). The face
/// sets its subtree to the light scheme (`CardSurface`), so the system controls on its back draw for ivory and the
/// page tokens read on it. Pack art keeps its natural colours on it.
extension Color {
    /// Legendary text and marks: #7F5E20 on light surfaces and the card face, #D3B475 on the dark page.
    static let goldInk = Color("CollectibleGoldInk")
    /// The quiet gold ground of the first-discovery moment.
    static let goldWash = Color("CollectibleGoldWash")
    /// The card face: warm ivory, the paper the pack paintings are painted on; fixed in both appearances.
    static let cardFace = Color("CollectibleFace")
    /// Text on the card face: deep teal (11:1 on the face).
    static let cardInk = Color("CollectibleInk")
    /// Supporting text on the card face (5.5:1).
    static let cardInkSecondary = Color("CollectibleInkSecondary")
    /// The outer edge and edition line of a card that is not Legendary.
    static let cardEdge = Color("CollectibleEdge")
    /// The botanical sprigs in the face's corners: decoration, never information.
    static let cardSprig = Color("CollectibleSprig")
    /// Text on the card face, under its name from before #116, for screens not yet reskinned (the circle feed, #118).
    static var cardIvory: Color { cardInk }
}

enum CollectibleLayout {
    /// The card's corner radius: modest.
    static let cardRadius: CGFloat = 16
    /// The art's slot on a card: square. A pack painting (3:4, on paper like the face) sits whole inside it; other art
    /// fills it.
    static let artAspectRatio: CGFloat = 1
    static let artRadius: CGFloat = 8
    /// The outer edge: gold on a Legendary card, teal otherwise.
    static func edgeWidth(isLegendary: Bool) -> CGFloat { isLegendary ? 5 : 2.5 }
}

/// The Legendary perimeter: the guide's two golds blended around the card, still (no glint, no motion).
extension ShapeStyle where Self == AngularGradient {
    static var legendaryFoil: AngularGradient {
        AngularGradient(
            colors: [0xD3B475, 0x9A7432, 0xE2CB91, 0xA9843E, 0xD3B475].map { hex in
                Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
            },
            center: .center
        )
    }
}

/// A card's surface: the ivory face, the outer edge (gold on a Legendary card, teal otherwise), a fine inner keyline,
/// and, on a front, a sprig in each top corner (drawn on the face, behind the content). Everything inside reads in the light scheme, whatever the app's.
struct CardSurface: ViewModifier {
    let isLegendary: Bool
    var sprigs: CGFloat? = 22

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: CollectibleLayout.cardRadius, style: .continuous)
        let edge = CollectibleLayout.edgeWidth(isLegendary: isLegendary)
        let inset = edge + 3
        content
            .frame(maxWidth: .infinity, alignment: .top)
            .background(alignment: .top) {
                if let sprigs {
                    HStack {
                        BotanicalSprig().fill(Color.cardSprig).frame(width: sprigs, height: sprigs)
                        Spacer(minLength: 0)
                        BotanicalSprig().fill(Color.cardSprig).frame(width: sprigs, height: sprigs).scaleEffect(x: -1)
                    }
                    .padding(inset + 2)
                    .accessibilityHidden(true)
                }
            }
            .background(Color.cardFace, in: shape)
            .overlay {
                RoundedRectangle(cornerRadius: max(CollectibleLayout.cardRadius - inset, 3), style: .continuous)
                    .strokeBorder(isLegendary ? Color.goldInk.opacity(0.6) : Color.cardEdge.opacity(0.35), lineWidth: 0.75)
                    .padding(inset)
                    .accessibilityHidden(true)
            }
            .overlay {
                shape.strokeBorder(isLegendary ? AnyShapeStyle(.legendaryFoil) : AnyShapeStyle(Color.cardEdge), lineWidth: edge)
                    .accessibilityHidden(true)
            }
            .environment(\.colorScheme, .light)
    }
}

/// The face's regional motif: three leaves fanning from a corner. Quiet, flat and still.
nonisolated struct BotanicalSprig: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
        func leaf(_ from: CGPoint, _ to: CGPoint, bulge: CGFloat) {
            let middle = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
            let normal = CGPoint(x: -(to.y - from.y) * bulge, y: (to.x - from.x) * bulge)
            path.move(to: from)
            path.addQuadCurve(to: to, control: CGPoint(x: middle.x + normal.x, y: middle.y + normal.y))
            path.addQuadCurve(to: from, control: CGPoint(x: middle.x - normal.x, y: middle.y - normal.y))
        }
        let base = point(0.05, 0.05)
        leaf(base, point(0.95, 0.22), bulge: 0.22)
        leaf(base, point(0.22, 0.95), bulge: 0.22)
        leaf(base, point(0.68, 0.68), bulge: 0.26)
        return path
    }
}

/// "Legendary · Your first" in the guide's gold: the words carry it, never a glint. On a tile too narrow for the whole
/// line it says "Legendary" (VoiceOver still hears "your first", from the tile's label).
struct LegendaryLabel: View {
    var compact = false

    var body: some View {
        if compact {
            ViewThatFits(in: .horizontal) {
                line(CardHeading.legendaryTitle)
                line("Legendary")
            }
        } else {
            line(CardHeading.legendaryTitle)
        }
    }

    private func line(_ text: String) -> some View {
        Text(text)
            .textCase(.uppercase)
            .font(compact ? CardFont.editionCompact : CardFont.edition)
            .tracking(compact ? CardFont.editionCompactTracking : CardFont.editionTracking)
            .foregroundStyle(Color.goldInk)
            .lineLimit(1)
    }
}

/// The card's top line (issues #54 and #116): "Legendary · Your first" in gold on the birder's first of a species,
/// else the set's edition ("Citrus edition", or "Uncharted") in teal, in small capitals, centred. The collector number
/// sits in the footer (`CardFooter`). An Uncharted card has no number; a Legendary one says "Uncharted" where the
/// number would be, since its label names no set.
struct CardHeading: View {
    static let legendaryTitle = "Legendary · Your first"

    let isLegendary: Bool
    /// Nil until the collection has placed the card.
    let placement: CardPlacement?
    var compact = false

    var body: some View {
        Group {
            if isLegendary {
                LegendaryLabel(compact: compact)
            } else if let placement {
                Text(placement.editionLabel)
                    .textCase(.uppercase)
                    .font(compact ? CardFont.editionCompact : CardFont.edition)
                    .tracking(compact ? CardFont.editionCompactTracking : CardFont.editionTracking)
                    .foregroundStyle(Color.cardEdge)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }

    static func numberText(isLegendary: Bool, placement: CardPlacement?) -> String? {
        guard let placement else { return nil }
        if case .numbered = placement { return placement.collectorNumber }
        return isLegendary ? placement.collectorNumber : nil
    }

    /// The heading for VoiceOver: "Legendary, your first" or the edition, then "number 21 of 160 in Los Angeles", or
    /// "Uncharted".
    static func accessibilityText(isLegendary: Bool, placement: CardPlacement?) -> [String?] {
        let edition = isLegendary ? "Legendary, your first" : placement.map(\.editionLabel)
        guard let placement else { return [edition] }
        switch placement {
        case .numbered(_, let setName, _, let number, let total): return [edition, "number \(number) of \(total) in \(setName)"]
        case .uncharted: return isLegendary ? [edition, CardPlacement.unchartedTitle] : [edition]
        }
    }
}

/// The front's quiet footer (design guide page 7, "A quiet personal imprint"): the place, the date and Heard or Seen,
/// the rarity in words, and the collector number after a fine rule; stacked when they don't fit side by side.
struct CardFooter: View {
    /// "Griffith Park · Nov 1, 2026 · Heard".
    let line: String
    /// "Common here in mid October", or that there is none; nil on a tile.
    var rarity: String? = nil
    /// "085/160", or "Uncharted" on a Legendary card outside every set.
    let number: String?
    /// What VoiceOver says for the number.
    var numberLabel: String? = nil

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 10) {
                texts.fixedSize()
                Spacer(minLength: 0)
                if number != nil {
                    Rectangle().fill(Color.cardEdge.opacity(0.4)).frame(width: 1, height: 24).accessibilityHidden(true)
                    numberView
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                texts.fixedSize(horizontal: false, vertical: true)
                numberView
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var texts: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(line)
                .font(CardFont.footer)
                .foregroundStyle(Color.cardInk)
                .accessibilityIdentifier("card-footer-line")
            if let rarity {
                Text(rarity)
                    .font(CardFont.footer)
                    .foregroundStyle(Color.cardInkSecondary)
                    .accessibilityIdentifier("card-rarity")
            }
        }
    }

    @ViewBuilder private var numberView: some View {
        if let number {
            Text(number)
                .font(CardFont.footer.monospacedDigit())
                .foregroundStyle(Color.cardInk)
                .accessibilityLabel(numberLabel ?? number)
                .accessibilityIdentifier("card-number")
        }
    }

    /// "Griffith Park · Nov 1, 2026 · Heard", without the place when there is none to show.
    static func line(place: String?, date: Date, method: SightingMethod) -> String {
        [place, date.formatted(date: .abbreviated, time: .omitted), method.title].compactMap { $0 }.joined(separator: " · ")
    }
}

/// The front's lore excerpt (design guide pages 5 and 17): the leading whole sentences of the approved lore, about 25 to
/// 40 words. Sentences are taken while the excerpt stays within 40 words; one under 25 may take one more sentence up to
/// 50, so a short opening doesn't leave a thin tale. The first sentence is always whole, however long. Nothing is cut
/// inside a sentence or shrunk to fit: the card grows instead (DECISIONS #32 and #33).
enum LoreExcerpt {
    static let targetWords = 40
    static let minimumWords = 25
    static let stretchWords = 50

    static func front(_ lore: String) -> String? {
        var taken: [String] = []
        var count = 0
        for sentence in sentences(lore) {
            let words = wordCount(sentence)
            if !taken.isEmpty, count + words > targetWords, !(count < minimumWords && count + words <= stretchWords) { break }
            taken.append(sentence)
            count += words
        }
        return taken.isEmpty ? nil : taken.joined(separator: " ")
    }

    static func sentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        return tokenizer.tokens(for: text.startIndex..<text.endIndex)
            .map { text[$0].trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}

/// One card of the collection as a thumbnail (issues #51 and #116): the Legendary label or the set's edition, the
/// name, the painting, the story title when the pack has one, and the date with Heard or Seen and the collector number.
/// No paragraph: the tale is read on the opened card. The art is `CardText.Art`'s, labelled as what it is (issue #57).
struct CardTile: View {
    @Environment(PackLibrary.self) private var library
    let sighting: Sighting
    let isLegendary: Bool
    let placement: CardPlacement?
    /// The story title in place of the pack's (#113, `PackLore.title`); nil reads the pack's.
    var storyTitle: String? = nil

    private var title: String? {
        storyTitle ?? library.species(scientificName: sighting.scientificName)?.species.lore?.title?.nilIfEmpty
    }

    var body: some View {
        let name = library.commonName(for: sighting)
        VStack(spacing: 6) {
            CardHeading(isLegendary: isLegendary, placement: placement, compact: true)
                .padding(.horizontal, 14)
            Text(name)
                .font(CardFont.tileName)
                .foregroundStyle(Color.cardInk)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            CardArtView(art: CardArtView.art(for: sighting, library: library, setID: placement?.setID), commonName: name)
            if let title {
                Text(title)
                    .font(CardFont.tileStoryTitle)
                    .foregroundStyle(Color.cardInk)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            CardFooter(
                line: CardFooter.line(place: nil, date: sighting.confirmedAt, method: sighting.method),
                number: CardHeading.numberText(isLegendary: isLegendary, placement: placement)
            )
        }
        .modifier(TileFrame(isLegendary: isLegendary))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        ([library.commonName(for: sighting), title] + CardHeading.accessibilityText(isLegendary: isLegendary, placement: placement) + [
            sighting.confirmedAt.formatted(date: .long, time: .shortened),
            sighting.method.title,
            CardArtView.art(for: sighting, library: library, setID: placement?.setID).label,
        ])
        .compactMap { $0 }
        .joined(separator: ", ")
    }
}

/// A grid tile's card surface, with a ring in the primary action's colour around it when it is the card last opened
/// from a gallery. A gallery's tiles (`isSelected` set) keep room for the ring whether or not it shows, so every tile
/// is the same size.
private struct TileFrame: ViewModifier {
    let isLegendary: Bool
    var isSelected: Bool?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: CollectibleLayout.cardRadius, style: .continuous)
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .modifier(CardSurface(isLegendary: isLegendary, sprigs: 16))
            .padding(isSelected == nil ? 0 : 4)
            .overlay {
                if isSelected == true {
                    RoundedRectangle(cornerRadius: CollectibleLayout.cardRadius + 4, style: .continuous)
                        .strokeBorder(Color.moss, lineWidth: 3)
                }
            }
            .contentShape(shape)
    }
}

/// One tile of a species gallery (issue #53): the Legendary label on the birder's first or the set's edition, the art,
/// and what tells two cards of one bird apart: the place, the date and time, Heard or Seen, and the collector number.
struct GalleryTile: View {
    @Environment(PackLibrary.self) private var library
    let sighting: Sighting
    /// The gallery's place for the card, nil for "Place not recorded".
    let place: String?
    let isLegendary: Bool
    let placement: CardPlacement?
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            CardHeading(isLegendary: isLegendary, placement: placement, compact: true)
                .padding(.horizontal, 14)
            CardArtView(art: CardArtView.art(for: sighting, library: library, setID: placement?.setID), commonName: library.commonName(for: sighting))
            VStack(alignment: .leading, spacing: 2) {
                Text(place ?? SpeciesGallery.PlaceFilter.notRecorded.title)
                    .font(CardFont.tileStoryTitle)
                    .foregroundStyle(Color.cardInk)
                Text(sighting.confirmedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(CardFont.footer)
                    .foregroundStyle(Color.cardInkSecondary)
                Text("\(sighting.confirmedAt.formatted(date: .omitted, time: .shortened)) · \(sighting.method.title)")
                    .font(CardFont.footer)
                    .foregroundStyle(Color.cardInkSecondary)
                if let number = CardHeading.numberText(isLegendary: isLegendary, placement: placement) {
                    Text(number)
                        .font(CardFont.footer.monospacedDigit())
                        .foregroundStyle(Color.cardInkSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .modifier(TileFrame(isLegendary: isLegendary, isSelected: isSelected))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        ([
            place ?? SpeciesGallery.PlaceFilter.notRecorded.title,
            sighting.confirmedAt.formatted(date: .long, time: .shortened),
            sighting.method.title,
        ] + CardHeading.accessibilityText(isLegendary: isLegendary, placement: placement) + [
            CardArtView.art(for: sighting, library: library, setID: placement?.setID).label,
        ])
        .compactMap { $0 }
        .joined(separator: ", ")
    }
}

/// A card's art (`CardText.Art`): photo or scene art from the frame store, the pack's painting or reference photo from
/// the pack, or a quiet bird placeholder, with its compact label under it (issue #57: "AI illustration", "Reference
/// photo"). A pack painting is drawn whole and feathered into the face, since it is painted on paper like the face;
/// every other picture fills the slot.
struct CardArtView: View {
    let art: CardText.Art
    let commonName: String
    /// The picture already loaded (the share sheet's renderer, issue #66); nil loads it from `art`.
    var image: UIImage? = nil

    /// What the card's art is: its own, else the pack art of its set's pack (`PackLibrary.packArt`), else the first
    /// pack photo of the species.
    static func art(for sighting: Sighting, library: PackLibrary, setID: String?) -> CardText.Art {
        let packArt = library.packArt(scientificName: sighting.scientificName, setID: setID).map { found in
            (url: found.pack.artURL(for: found.art), credit: found.pack.sourcePhotos(of: found.art).first?.creditLine)
        }
        let reference = library.species(scientificName: sighting.scientificName).flatMap { found in
            found.species.photos.first.map { (url: found.pack.phoneImageURL(for: $0), credit: $0.creditLine) }
        }
        return CardText.Art(sighting: sighting, packArt: packArt, reference: reference)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Color.clear
                .aspectRatio(CollectibleLayout.artAspectRatio, contentMode: .fit)
                .overlay { picture }
                .clipShape(RoundedRectangle(cornerRadius: CollectibleLayout.artRadius, style: .continuous))
                .accessibilityHidden(true)
            Text(art.label)
                .font(CardFont.credit)
                .foregroundStyle(Color.cardInkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("card-art-credit")
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var picture: some View {
        switch art {
        case .packArt(let url, _):
            if let image {
                Image(uiImage: image).resizable().scaledToFit().modifier(PaperFeather())
            } else {
                PackImage(url: url, painting: true)
            }
        case .photoArt(let path), .sceneArt(let path):
            if let image {
                Image(uiImage: image).resizable().scaledToFill().allowsHitTesting(false)
            } else {
                FrameImage(frameImagePath: path, zoom: 1)
            }
        case .referencePhoto(let url, _):
            if let image {
                Image(uiImage: image).resizable().scaledToFill().allowsHitTesting(false)
            } else {
                PackImage(url: url)
            }
        case .none:
            MissingArt()
        }
    }
}

/// A pack painting's edges, faded into the face so the painting's paper and the card's are one.
struct PaperFeather: ViewModifier {
    func body(content: Content) -> some View {
        let stops: [Gradient.Stop] = [.init(color: .clear, location: 0), .init(color: .black, location: 0.06), .init(color: .black, location: 0.94), .init(color: .clear, location: 1)]
        content.mask {
            LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
                .mask(LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom))
        }
    }
}

/// The missing-art face: a quiet bird on a faint wash of the edge colour, so the card reads as waiting for its art
/// rather than broken; the label under it says "No art yet".
private struct MissingArt: View {
    var body: some View {
        Color.cardEdge.opacity(0.07)
            .overlay {
                Image(systemName: "bird")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Color.cardEdge.opacity(0.55))
            }
    }
}
