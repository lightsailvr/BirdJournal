import Identification

/// A page shown on the lens. Indices refer to the session's candidate stack, which only ever appends. Every page
/// fits the canvas: the glasses do not scroll a view while the app subscribes to Inputs (DECISIONS.md, "Lens UI").
public enum LensPage: Sendable, Hashable {
    /// Root page: every species heard this session, one row each, with the machine's `selection` highlighted.
    case list
    /// The photo page for the species at `index`: photo, name and match rate, status strip, hint.
    case species(index: Int)
    /// The details page under the photo page: identification text, credit and the "Add to my list" action (or its
    /// saved mark).
    case details(index: Int)
    /// A problem the run wants the wearer to know about, over whichever page they were on (issue #10). Swipe right,
    /// Back or a tap is the way back to that page.
    case problem(LensProblem)

    /// The stack index the page is about, nil on the root and on a problem page.
    public var index: Int? {
        switch self {
        case .list, .problem: nil
        case .species(let index), .details(let index): index
        }
    }
}

/// What can go wrong with a run while the lens is still reachable (issue #10).
public enum LensProblem: Sendable, Hashable {
    /// No location fix: identification runs without the regional filter.
    case noLocation
    /// The link to the glasses dropped and came back; the run kept listening meanwhile.
    case connectionLost
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
    /// The "Add to my list" button on a details page.
    case save
}

/// What the adapter must do after an event, besides rendering the new page.
public enum LensEffect: Sendable, Equatable {
    /// The wearer said "Add to my list": write a Sighting with the camera frame from this moment.
    case saveSighting(Candidate)
    /// Back on the root: end the glasses session.
    case endSession
}

/// Pure lens state machine (spec "Lens session"): folds `CandidateStack` updates and semantic input events into
/// the page to render and at most one side effect per event.
///
/// Page map (DECISIONS.md, "Lens UI", issue #24). The list is a menu the app drives, because the glasses hand Nav
/// and Select to an app that subscribes to Inputs instead of moving focus between tappable rows (and do not scroll
/// a view either): swipe down/up move the highlight, and a tap or swipe left opens the highlighted species' photo
/// page. From the photo page swipe down opens the details page and swipe up returns; on either, swipe left is the
/// next species' photo and swipe right is back to the list (the only way back on real glasses, which do not deliver
/// Back). A tap or the button on the details page is "Add to my list"; a tap on the photo page does nothing, so a
/// bird is never added by accident. The stack never reorders and new species append at the end, so an update
/// never moves the page the wearer is on. A reported problem covers the current page until swipe right, Back or a
/// tap returns there (issue #10).
///
/// The list shows the stack in `order` (issue #42): calling birds first, then the rest most recently heard first.
/// The highlight is unpinned until the wearer swipes: it sits on row one, so the calling bird is the highlighted
/// row and a tap opens it. Swipe down or up pins it to a species, and it stays on that bird as the list moves under
/// it; swipe right on the list unpins it. Opening a card leaves the pin as it is; paging to the next species on a
/// card pins to that species, so coming back lands on it.
public struct LensStateMachine: Sendable, Equatable {
    public private(set) var page: LensPage = .list
    /// The page a problem page covers, for the way back.
    private var coveredPage: LensPage = .list
    /// The candidates the pages index into, in admission order.
    public private(set) var stack = CandidateStack()
    /// The order the list shows the stack in, as of the last update.
    public private(set) var order = SpeciesListOrder()
    /// The species the highlight is pinned to by a swipe, nil while it follows row one.
    public private(set) var pinnedSpecies: Species?
    /// Stack indices whose sighting has been saved this session; their pages show the saved mark instead of the
    /// button. A later tap on a saved details page saves again (the run updates the sighting, spec user story 33);
    /// one press that hardware delivers twice, as a click and a select, is deduplicated by the adapter, which has a
    /// clock.
    public private(set) var savedIndices: Set<Int> = []

    public init() {}

    /// The candidate the current page is about, nil on the list.
    public var currentCandidate: Candidate? {
        page.index.map { stack.candidates[$0] }
    }

    /// The highlighted row of the list as a stack index: the pinned species, else row one (0 on an empty list).
    public var selection: Int {
        if let pinnedSpecies, let index = stack.candidates.firstIndex(where: { $0.species == pinnedSpecies }) {
            return index
        }
        return order.indices.first ?? 0
    }

    // MARK: - Stack

    /// Takes the latest stack at session time `time` (seconds since the run started, the clock `Candidate` times
    /// are on). Returns true if anything the pages show changed: the stack, or the list order, which also moves when a
    /// calling marker lapses with the stack unchanged. A stack that does not continue the current one (a new
    /// session) restarts on the list with nothing saved and nothing pinned, so no page can index past the end.
    @discardableResult
    public mutating func update(with stack: CandidateStack, at time: Double) -> Bool {
        let stackChanged = stack != self.stack
        let continues = stack.count >= self.stack.count
            && zip(stack.candidates, self.stack.candidates).allSatisfy { $0.species == $1.species }
        self.stack = stack
        if !continues {
            page = .list
            coveredPage = .list
            pinnedSpecies = nil
            savedIndices = []
            order = SpeciesListOrder()
        }
        let previousOrder = order
        order.update(with: stack, at: time)
        return stackChanged || order != previousOrder
    }

    // MARK: - Problems

    /// Shows `problem` over the current page (or in place of the problem already showing) until the wearer swipes
    /// right, taps or goes back.
    public mutating func report(_ problem: LensProblem) {
        if case .problem = page {} else { coveredPage = page }
        page = .problem(problem)
    }

    // MARK: - Gestures

    /// Applies a gesture to the current page. Gestures with no meaning on the current page are ignored.
    public mutating func apply(_ gesture: LensGesture) -> LensEffect? {
        switch (page, gesture) {
        case (.list, .swipeDown):
            pin(rowOffset: 1)
        case (.list, .swipeUp):
            pin(rowOffset: -1)
        case (.list, .tap), (.list, .swipeLeft):
            if !stack.isEmpty { page = .species(index: selection) }
        case (.list, .swipeRight):
            pinnedSpecies = nil
        case (.list, .back):
            return .endSession

        case let (.species(index), .swipeLeft), let (.details(index), .swipeLeft):
            if index + 1 < stack.count { open(index + 1) }
        case (.species, .swipeRight), (.species, .back), (.details, .swipeRight), (.details, .back):
            page = .list
        case let (.species(index), .swipeDown):
            page = .details(index: index)
        case (.species, .swipeUp), (.species, .tap):
            break
        case let (.details(index), .swipeUp):
            page = .species(index: index)
        case (.details, .swipeDown):
            break
        case let (.details(index), .tap):
            return save(index)

        case (.problem, .swipeRight), (.problem, .back), (.problem, .tap):
            page = coveredPage
        case (.problem, .swipeLeft), (.problem, .swipeUp), (.problem, .swipeDown):
            break
        }
        return nil
    }

    /// A tap on a card element, delivered by the Display: the Add button on its own details page. Anything else is
    /// ignored.
    public mutating func press(_ action: LensAction) -> LensEffect? {
        switch (page, action) {
        case let (.details(index), .save):
            return save(index)
        case (.list, .save), (.species, .save), (.problem, .save):
            return nil
        }
    }

    /// Pins the highlight to the species `rowOffset` rows from the highlighted one in list order; nothing past the
    /// ends of the list.
    private mutating func pin(rowOffset: Int) {
        guard let position = order.position(of: selection) else { return }
        let target = position + rowOffset
        guard order.indices.indices.contains(target) else { return }
        pinnedSpecies = stack.candidates[order.indices[target]].species
    }

    private mutating func open(_ index: Int) {
        page = .species(index: index)
        pinnedSpecies = stack.candidates[index].species
    }

    private mutating func save(_ index: Int) -> LensEffect {
        savedIndices.insert(index)
        return .saveSighting(stack.candidates[index])
    }
}
