import Album
import NaturalLanguage
import Pack
import SwiftUI

/// The card's tokens (issue #116, Featherguild design guide 1.0 pages 5–9) and a sighting's art, which it draws until #137:
/// since #134 what you collect is the patch and its paper card (`Patch/`), though the ink tokens here are the paper's too.
/// There is no Legendary and no gold since #132.
extension Color {
    /// The card face: warm ivory, the paper the pack paintings are painted on; fixed in both appearances.
    static let cardFace = Color("CollectibleFace")
    /// Text on the card face: deep teal (11:1 on the face).
    static let cardInk = Color("CollectibleInk")
    /// Supporting text on the card face (5.5:1).
    static let cardInkSecondary = Color("CollectibleInkSecondary")
    /// The outer edge and the edition line.
    static let cardEdge = Color("CollectibleEdge")
    /// Text on the card face, under its name from before #116, for screens not yet reskinned (the circle feed, #118).
    static var cardIvory: Color { cardInk }
}

enum CollectibleLayout {
    /// The art's slot on a card: square. A pack painting (3:4, on paper like the face) sits whole inside it; other art
    /// fills it.
    static let artAspectRatio: CGFloat = 1
    static let artRadius: CGFloat = 8
}

/// What the paper card's edition line says to VoiceOver.
enum CardHeading {
    /// The edition, then "number 21 of 160 in Los Angeles"; or "Uncharted".
    static func accessibilityText(placement: CardPlacement?) -> [String?] {
        guard let placement else { return [nil] }
        switch placement {
        case .numbered(_, let setName, let edition, let number, let total): return [edition, "number \(number) of \(total) in \(setName)"]
        case .uncharted: return [CardPlacement.unchartedTitle]
        }
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
