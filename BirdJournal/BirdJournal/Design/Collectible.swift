import Album
import NaturalLanguage
import SwiftUI

/// The card's tokens (issue #116, Featherguild design guide 1.0 pages 5–9): since #134 what you collect is the patch and
/// its paper card (`Patch/`), and the ink tokens here are the paper's. There is no Legendary and no gold since #132.
extension Color {
    /// The card face: warm ivory; fixed in both appearances.
    static let cardFace = Color("CollectibleFace")
    /// Text on the card face: deep teal (11:1 on the face).
    static let cardInk = Color("CollectibleInk")
    /// Supporting text on the card face (5.5:1).
    static let cardInkSecondary = Color("CollectibleInkSecondary")
    /// The outer edge and the edition line.
    static let cardEdge = Color("CollectibleEdge")
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
