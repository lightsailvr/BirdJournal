import Album
import Foundation
import Observation

/// What the Collection tab remembers while the app runs (issue #117, design guide page 10: "preserve filters, sorting
/// and scroll position when returning"): its mode, the search, the Patches sort and each mode's scroll offset. The root
/// owns it, so a card opened and closed, another tab and back, or the Collection page itself being rebuilt all come
/// back to the same place. Nothing here is stored: a new launch starts on Patches, newest first, at the top.
@MainActor @Observable
final class CollectionState {
    var mode: JournalView.Mode = .cards
    /// The search: the filter over every mode.
    var query = ""
    var sort: CardSort = .newest
    /// How far down each mode was scrolled, in points from the top of its content.
    var offsets: [JournalView.Mode: CGFloat] = [:]
}

/// The order of the Patches view.
enum CardSort: String, CaseIterable, Identifiable {
    /// The most recently sewn first.
    case newest = "Newest first"
    case oldest = "Oldest first"
    /// By set, then by collector number (a species position, issue #54); Uncharted patches last, newest first.
    case collectorNumber = "Collector number"

    var id: Self { self }

    /// `patches` (the most recently sewn first, as `CardCollection.patches` keeps them) in this order. Patches with no
    /// number keep their newest-first order under the collector number, so the order is stable.
    func ordered(_ patches: [CardCollection.Patch]) -> [CardCollection.Patch] {
        switch self {
        case .newest:
            return patches
        case .oldest:
            return patches.reversed()
        case .collectorNumber:
            let keyed = patches.enumerated().map { position, patch -> (key: (String, Int, Int), patch: CardCollection.Patch) in
                switch patch.placement {
                case .numbered(_, let setName, _, let number, _): ((setName, number, position), patch)
                case .uncharted: (("\u{10FFFF}", Int.max, position), patch)
                }
            }
            return keyed.sorted { $0.key < $1.key }.map(\.patch)
        }
    }
}
