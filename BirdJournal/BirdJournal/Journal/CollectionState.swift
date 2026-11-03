import Album
import Foundation
import Observation

/// What the Collection tab remembers while the app runs (issue #117, design guide page 10: "preserve filters, sorting
/// and scroll position when returning"): its mode, the search, the Cards sort and each mode's scroll offset. The root
/// owns it, so a card opened and closed, another tab and back, or the Collection page itself being rebuilt all come
/// back to the same place. Nothing here is stored: a new launch starts on Cards, newest first, at the top.
@MainActor @Observable
final class CollectionState {
    var mode: JournalView.Mode = .cards
    /// The search: the filter over every mode.
    var query = ""
    var sort: CardSort = .newest
    /// How far down each mode was scrolled, in points from the top of its content.
    var offsets: [JournalView.Mode: CGFloat] = [:]
}

/// The order of the Cards view.
enum CardSort: String, CaseIterable, Identifiable {
    case newest = "Newest first"
    case oldest = "Oldest first"
    /// By set, then by collector number (a species position, issue #54); Uncharted cards last, newest first.
    case collectorNumber = "Collector number"

    var id: Self { self }

    /// `cards` (newest first, as `CardCollection.cards` keeps them) in this order. A species' cards keep their
    /// newest-first order under the collector number, so the order is stable.
    func ordered(_ cards: [CardCollection.Entry], in collection: CardCollection) -> [CardCollection.Entry] {
        switch self {
        case .newest:
            return cards
        case .oldest:
            return cards.reversed()
        case .collectorNumber:
            let keyed = cards.enumerated().map { position, card -> (key: (String, Int, Int), card: CardCollection.Entry) in
                switch collection.placement(of: card.identifier) {
                case .numbered(_, let setName, _, let number, _)?: ((setName, number, position), card)
                default: (("\u{10FFFF}", Int.max, position), card)
                }
            }
            return keyed.sorted { $0.key < $1.key }.map(\.card)
        }
    }
}
