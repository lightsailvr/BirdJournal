import Identification

/// A page shown on the lens: a card and the screenful of it on the canvas. Indices refer to the session's candidate
/// stack, which only ever appends. Each send must fit the canvas (the mock anchors overflow at the bottom, cutting
/// the top of a tall card; see DECISIONS.md, "Lens UI"), so a card is paged by screenful rather than scrolled.
public enum LensPage: Sendable, Hashable {
    /// Root page: every species heard this session, one tappable row each, `screenful` rows-pages down.
    case list(screenful: Int)
    /// The card for the species at `index`: photo, name and match rate on the first screenful; identification
    /// text, credit and the "This is my bird" action (or its saved mark) on the next.
    case species(index: Int, screenful: Int)

    /// The stack index the page is about, nil on the root.
    public var index: Int? {
        switch self {
        case .list: nil
        case .species(let index, _): index
        }
    }

    /// The screenful of the card the page shows, from 0.
    public var screenful: Int {
        switch self {
        case .list(let screenful), .species(_, let screenful): screenful
        }
    }
}

/// Semantic input events as the app sees them. Swipes arrive as Nav events and taps as Select events from the
/// Neural Band. Real Display glasses do not deliver `back` (the two-finger tap ends the session instead); the rule
/// is here for when the hardware does, behind `consumeBack` (DECISIONS.md, "Lens UI").
public enum LensGesture: Sendable, Hashable, CaseIterable {
    case swipeLeft
    case swipeRight
    case swipeUp
    case swipeDown
    case tap
    case back

    /// The gesture as the wearer performed it, for the phone log.
    public var name: String {
        switch self {
        case .swipeLeft: "Swipe left"
        case .swipeRight: "Swipe right"
        case .swipeUp: "Swipe up"
        case .swipeDown: "Swipe down"
        case .tap: "Tap"
        case .back: "Back"
        }
    }
}

/// A tappable element on a lens card, activated through the Display rather than Inputs.
public enum LensAction: Sendable, Hashable {
    /// The "This is my bird" button on a species card.
    case save
    /// A row on the species list: open that species' card.
    case open(index: Int)
}

/// What the adapter must do after an event, besides rendering the new page.
public enum LensEffect: Sendable, Equatable {
    /// The wearer said "This is my bird": write a Sighting with the camera frame from this moment.
    case saveSighting(Candidate)
    /// Back on the root: end the glasses session.
    case endSession
}

/// Pure lens state machine (spec "Lens session"): folds `CandidateStack` updates and semantic input events into
/// the page to render and at most one side effect per event.
///
/// Page map (DECISIONS.md, "Lens UI", issue #24): list ⇄ species cards (swipe left/right; right past the first
/// card returns to the list; a row tap opens a card; every card opens on its first screenful), swipe down/up page
/// the screenfuls of the list or the card, and up from a card's first screenful is back to the list. A tap or the
/// Save button on a card is "This is my bird", once per species. Back returns to the list and ends the session on
/// the root. The stack never reorders and new species append at the end, so an update never moves the page the
/// wearer is on.
public struct LensStateMachine: Sendable, Equatable {
    public private(set) var page: LensPage = .list(screenful: 0)
    /// The candidates the pages index into, in admission order.
    public private(set) var stack = CandidateStack()
    /// Stack indices whose sighting has been saved this session; their cards show the saved mark instead of the
    /// button, and a second tap (hardware may deliver one press twice, as a click and a select) does nothing.
    public private(set) var savedIndices: Set<Int> = []

    public init() {}

    /// The candidate the current page is about, nil on the list.
    public var currentCandidate: Candidate? {
        page.index.map { stack.candidates[$0] }
    }

    // MARK: - Stack

    /// Takes the latest stack. Returns true if anything the pages show changed. A stack that does not continue the
    /// current one (a new session) restarts on the list with nothing saved, so no page can index past the end.
    @discardableResult
    public mutating func update(with stack: CandidateStack) -> Bool {
        guard stack != self.stack else { return false }
        let continues = stack.count >= self.stack.count
            && zip(stack.candidates, self.stack.candidates).allSatisfy { $0.species == $1.species }
        self.stack = stack
        if !continues {
            page = .list(screenful: 0)
            savedIndices = []
        }
        return true
    }

    // MARK: - Gestures

    /// Applies a gesture to the current page, whose card has `screenfuls` screenfuls (at least one; the renderer
    /// knows, the machine does not). Gestures with no meaning on the current page are ignored.
    public mutating func apply(_ gesture: LensGesture, screenfuls: Int) -> LensEffect? {
        let last = max(screenfuls - 1, 0)
        switch (page, gesture) {
        case (.list, .swipeLeft), (.list, .swipeRight):
            if !stack.isEmpty { page = .species(index: 0, screenful: 0) }
        case let (.list(screenful), .swipeDown):
            page = .list(screenful: min(screenful + 1, last))
        case let (.list(screenful), .swipeUp):
            page = .list(screenful: max(min(screenful, last) - 1, 0))
        case (.list, .back):
            return .endSession
        case (.list, .tap):
            // Rows are opened through `press`.
            break

        case let (.species(index, _), .swipeLeft):
            if index + 1 < stack.count { page = .species(index: index + 1, screenful: 0) }
        case let (.species(index, _), .swipeRight):
            page = index == 0 ? .list(screenful: 0) : .species(index: index - 1, screenful: 0)
        case let (.species(index, screenful), .swipeDown):
            page = .species(index: index, screenful: min(screenful + 1, last))
        case let (.species(index, screenful), .swipeUp):
            page = screenful == 0 ? .list(screenful: 0) : .species(index: index, screenful: max(min(screenful, last) - 1, 0))
        case let (.species(index, _), .tap):
            return save(index)
        case (.species, .back):
            page = .list(screenful: 0)
        }
        return nil
    }

    /// A tap on a card element, delivered by the Display: the Save button on its own card, or a row on the list.
    /// Anything else is ignored.
    public mutating func press(_ action: LensAction) -> LensEffect? {
        switch (page, action) {
        case let (.species(index, _), .save):
            return save(index)
        case let (.list, .open(index)) where stack.candidates.indices.contains(index):
            page = .species(index: index, screenful: 0)
            return nil
        case (.species, .open), (.list, .save), (.list, .open):
            return nil
        }
    }

    private mutating func save(_ index: Int) -> LensEffect? {
        guard !savedIndices.contains(index) else { return nil }
        savedIndices.insert(index)
        return .saveSighting(stack.candidates[index])
    }
}
