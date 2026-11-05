import Album
import NaturalLanguage
import Pack
import SwiftUI

/// The card's tokens and the one sighting's card face (issue #116, Featherguild design guide 1.0 pages 5–9), which only the
/// share image (until #136) and a sighting's art (until #137) still draw: since #134 what you collect is the patch and its
/// paper card (`Patch/`), though the ink tokens here are the paper's too. A face is an ivory object in both appearances
/// and sets its subtree to the light scheme (`CardSurface`). There is no Legendary and no gold since #132.
extension Color {
    /// The card face: warm ivory, the paper the pack paintings are painted on; fixed in both appearances.
    static let cardFace = Color("CollectibleFace")
    /// Text on the card face: deep teal (11:1 on the face).
    static let cardInk = Color("CollectibleInk")
    /// Supporting text on the card face (5.5:1).
    static let cardInkSecondary = Color("CollectibleInkSecondary")
    /// The outer edge and the edition line.
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
    /// The teal outer edge.
    static let edgeWidth: CGFloat = 2.5
}

/// A card's surface: the ivory face, the teal outer edge, a fine inner keyline, and, on a front, a sprig in each top
/// corner (drawn on the face, behind the content). Everything inside reads in the light scheme, whatever the app's.
struct CardSurface: ViewModifier {
    var sprigs: CGFloat? = 22

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: CollectibleLayout.cardRadius, style: .continuous)
        let edge = CollectibleLayout.edgeWidth
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
                    .strokeBorder(Color.cardEdge.opacity(0.35), lineWidth: 0.75)
                    .padding(inset)
                    .accessibilityHidden(true)
            }
            .overlay {
                shape.strokeBorder(Color.cardEdge, lineWidth: edge)
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

/// The card's top line (issues #54 and #116): the set's edition ("Citrus edition", or "Uncharted") in teal, in small
/// capitals, centred. The collector number sits in the footer (`CardFooter`); an Uncharted card has none.
struct CardHeading: View {
    /// Nil until the collection has placed the card.
    let placement: CardPlacement?
    var compact = false

    var body: some View {
        Group {
            if let placement {
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

    static func numberText(placement: CardPlacement?) -> String? {
        guard let placement, case .numbered = placement else { return nil }
        return placement.collectorNumber
    }

    /// The heading for VoiceOver: the edition, then "number 21 of 160 in Los Angeles"; or "Uncharted".
    static func accessibilityText(placement: CardPlacement?) -> [String?] {
        guard let placement else { return [nil] }
        switch placement {
        case .numbered(_, let setName, let edition, let number, let total): return [edition, "number \(number) of \(total) in \(setName)"]
        case .uncharted: return [CardPlacement.unchartedTitle]
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
    /// "085/160"; nil outside every set.
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

/// The share image's face until #136 draws the patch and its paper card: the story-first front (issue #116, design guide page 5, the reference card): the edition, the
/// bird's name upright and its scientific name in italics, the painting with its compact credit,
/// then the tale: the story title when the pack has an approved one (#113), and an excerpt of the approved lore in a true italic
/// serif (`LoreExcerpt`: whole sentences, about 25–40 words). Without a title the excerpt leads; without lore the tale
/// is left out. Then the quiet footer: the place, the date and Heard or Seen, the rarity in words, and the collector
/// number. Nothing is clipped or shrunk: at large text sizes
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
            CardArtView(art: art, commonName: commonName, image: artImage)
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
