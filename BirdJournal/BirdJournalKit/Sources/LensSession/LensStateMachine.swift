import Identification

/// A page shown on the lens. Indices refer to the session's candidate stack, which only ever appends. A page is
/// one tall card that the glasses scroll vertically (verified on hardware, DECISIONS.md, "Lens UI").
public enum LensPage: Sendable, Hashable {
    /// Root page: every species heard this session, one tappable row each.
    case list
    /// The card for the species at `index`: photo, name and match rate, then identification text, credit and the
    /// "This is my bird" action (or its saved mark).
    case species(index: Int)

    /// The stack index the page is about, nil on the root.
    public var index: Int? {
        switch self {
        case .list: nil
        case .species(let index): index
        }
    }
}

/// Semantic input events as the app sees them. Swipes arrive as Nav events and taps as Select events from the
/// Neural Band; the middle-finger tap arrives as Back, which reaches the app because Inputs is attached with
/// `consumeBack` (DECISIONS.md, "Lens UI").
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
/// Page map (DECISIONS.md, "Lens UI", issue #24): list → first species card (swipe left) or any card (a row tap);
/// swipe left/right move between cards and stop at the ends. Back (the middle-finger tap) is the only way back: a
/// card → the list, the list → end the session. Swipe up and down scroll the card on the glasses, so the machine
/// ignores them. A tap or the Save button on a card is "This is my bird". The stack never reorders and new species
/// append at the end, so an update never moves the page the wearer is on.
public struct LensStateMachine: Sendable, Equatable {
    public private(set) var page: LensPage = .list
    /// The candidates the pages index into, in admission order.
    public private(set) var stack = CandidateStack()
    /// Stack indices whose sighting has been saved this session; their cards show the saved mark instead of the
    /// button. A later tap on a saved card saves again (the run updates the sighting, spec user story 33); one press
    /// that hardware delivers twice, as a click and a select, is deduplicated by the adapter, which has a clock.
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
            page = .list
            savedIndices = []
        }
        return true
    }

    // MARK: - Gestures

    /// Applies a gesture to the current page. Gestures with no meaning on the current page are ignored.
    public mutating func apply(_ gesture: LensGesture) -> LensEffect? {
        switch (page, gesture) {
        case (.list, .swipeLeft):
            if !stack.isEmpty { page = .species(index: 0) }
        case (.list, .back):
            return .endSession
        case (.list, .swipeRight), (.list, .swipeUp), (.list, .swipeDown), (.list, .tap):
            // Nothing before the first card; the list scrolls on the glasses; rows are opened through `press`.
            break

        case let (.species(index), .swipeLeft):
            if index + 1 < stack.count { page = .species(index: index + 1) }
        case let (.species(index), .swipeRight):
            if index > 0 { page = .species(index: index - 1) }
        case (.species, .swipeUp), (.species, .swipeDown):
            // The card scrolls on the glasses.
            break
        case let (.species(index), .tap):
            return save(index)
        case (.species, .back):
            page = .list
        }
        return nil
    }

    /// A tap on a card element, delivered by the Display: the Save button on its own card, or a row on the list.
    /// Anything else is ignored.
    public mutating func press(_ action: LensAction) -> LensEffect? {
        switch (page, action) {
        case let (.species(index), .save):
            return save(index)
        case let (.list, .open(index)) where stack.candidates.indices.contains(index):
            page = .species(index: index)
            return nil
        case (.species, .open), (.list, .save), (.list, .open):
            return nil
        }
    }

    private mutating func save(_ index: Int) -> LensEffect {
        savedIndices.insert(index)
        return .saveSighting(stack.candidates[index])
    }
}
