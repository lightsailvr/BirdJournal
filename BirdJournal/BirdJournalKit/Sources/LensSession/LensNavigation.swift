/// A page shown on the lens. Indices refer to the session's candidate stack, which only ever appends.
public enum LensPage: Sendable, Equatable {
    /// Root page: "N species heard".
    case listening
    /// Photo card for the species at `index`.
    case photo(index: Int)
    /// Field marks, size, habitat and credit for the species at `index`.
    case description(index: Int)
    /// Confirm page for the species at `index`; Save is the primary action.
    case confirm(index: Int)
}

/// Gestures as the app sees them. Swipes arrive as Nav events and taps as Select events from the Neural Band.
/// A `back` event is added when the hardware delivers one (DECISIONS.md: nested Back behind `consumeBack`).
public enum LensGesture: Sendable, Equatable {
    case swipeLeft
    case swipeRight
    case swipeUp
    case swipeDown
    case tap
}

/// Pure page-map reducer for the lens (DECISIONS.md, "Lens UI").
///
/// Listening ⇄ photo pages (swipe left/right), photo ⇄ description (swipe down/up), photo → confirm (tap),
/// confirm → photo (swipe up), photo → listening (swipe up). New species append to the end and never move
/// the page the wearer is on.
public struct LensNavigation: Sendable, Equatable {
    public private(set) var page: LensPage = .listening
    public private(set) var speciesCount: Int = 0

    public init() {}

    /// Records that a new species was added to the end of the candidate stack.
    public mutating func speciesAppended() {
        speciesCount += 1
    }

    /// Applies a gesture to the current page. Gestures with no meaning on the current page are ignored.
    public mutating func apply(_ gesture: LensGesture) {
        switch (page, gesture) {
        case (.listening, .swipeLeft), (.listening, .swipeRight):
            if speciesCount > 0 { page = .photo(index: 0) }

        case let (.photo(index), .swipeLeft):
            if index + 1 < speciesCount { page = .photo(index: index + 1) }
        case let (.photo(index), .swipeRight):
            page = index == 0 ? .listening : .photo(index: index - 1)
        case let (.photo(index), .swipeDown):
            page = .description(index: index)
        case (.photo, .swipeUp):
            page = .listening
        case let (.photo(index), .tap):
            page = .confirm(index: index)

        case let (.description(index), .swipeUp), let (.confirm(index), .swipeUp):
            page = .photo(index: index)

        default:
            break
        }
    }
}
