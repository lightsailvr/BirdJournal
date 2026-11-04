import Album
import Foundation
import Observation

/// What the Collection tab remembers while the app runs (issue #117, design guide page 10: "preserve filters, sorting
/// and scroll position when returning"): its mode, the search, the board and each mode's scroll offset. The root
/// owns it, so a card opened and closed, another tab and back, or the Collection page itself being rebuilt all come
/// back to the same place. Nothing here is stored: a new launch starts on Patches, at the top of the set you're in.
@MainActor @Observable
final class CollectionState {
    var mode: JournalView.Mode = .cards
    /// The search: the filter over every mode.
    var query = ""
    /// The board the birder chose; nil shows the set they're in.
    var board: BoardChoice?
    /// How far down each mode was scrolled, in points from the top of its content.
    var offsets: [JournalView.Mode: CGFloat] = [:]
}
