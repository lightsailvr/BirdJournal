import Identification

/// A page shown on the lens. Indices refer to the session's candidate stack, which only ever appends. A page is
/// one tall card that the glasses scroll vertically (verified on hardware, DECISIONS.md, "Lens UI").
public enum LensPage: Sendable, Hashable {
    /// Root page: every species heard this session, one row each, with the machine's `selection` highlighted.
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
/// Neural Band. Real glasses do not deliver `back` (DAT 1.0.0 Inputs docs, "Current limitations"): the system's
/// back gesture ends the display session instead. The rule is here for the mock and for when hardware delivers it.
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
/// Page map (DECISIONS.md, "Lens UI", issue #24). The list is a menu the app drives, because the glasses hand Nav
/// and Select to an app that subscribes to Inputs instead of moving focus between tappable rows: swipe down/up move
/// `selection`, and a tap or swipe left opens the selected species. On a card, swipe left is the next species and
/// swipe right is back to the list (the only way back on real glasses, which do not deliver Back); swipe up and
/// down scroll the card on the glasses, so the machine ignores them; a tap or the Save button is "This is my bird".
/// The stack never reorders and new species append at the end, so an update never moves the page the wearer is on.
public struct LensStateMachine: Sendable, Equatable {
    public private(set) var page: LensPage = .list
    /// The candidates the pages index into, in admission order.
    public private(set) var stack = CandidateStack()
    /// The highlighted row of the list, a stack index; follows the card the wearer was on.
    public private(set) var selection = 0
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
            selection = 0
            savedIndices = []
        }
        return true
    }

    // MARK: - Gestures

    /// Applies a gesture to the current page. Gestures with no meaning on the current page are ignored.
    public mutating func apply(_ gesture: LensGesture) -> LensEffect? {
        switch (page, gesture) {
        case (.list, .swipeDown):
            if selection + 1 < stack.count { selection += 1 }
        case (.list, .swipeUp):
            if selection > 0 { selection -= 1 }
        case (.list, .tap), (.list, .swipeLeft):
            if !stack.isEmpty { page = .species(index: selection) }
        case (.list, .swipeRight):
            break
        case (.list, .back):
            return .endSession

        case let (.species(index), .swipeLeft):
            if index + 1 < stack.count { open(index + 1) }
        case (.species, .swipeRight), (.species, .back):
            page = .list
        case (.species, .swipeUp), (.species, .swipeDown):
            // The card scrolls on the glasses.
            break
        case let (.species(index), .tap):
            return save(index)
        }
        return nil
    }

    /// A tap on a card element, delivered by the Display: the Save button on its own card. Anything else is ignored.
    public mutating func press(_ action: LensAction) -> LensEffect? {
        switch (page, action) {
        case let (.species(index), .save):
            return save(index)
        case (.list, .save):
            return nil
        }
    }

    private mutating func open(_ index: Int) {
        page = .species(index: index)
        selection = index
    }

    private mutating func save(_ index: Int) -> LensEffect {
        savedIndices.insert(index)
        return .saveSighting(stack.candidates[index])
    }
}
