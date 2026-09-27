import Identification

/// A page shown on the lens. Indices refer to the session's candidate stack, which only ever appends.
public enum LensPage: Sendable, Hashable {
    /// Root page: "N species heard".
    case listening
    /// Photo card for the species at `index`: image, common name, confidence.
    case photo(index: Int)
    /// Field marks, size, habitat and photo credit for the species at `index`.
    case description(index: Int)
    /// Confirm page for the species at `index`; Save is the primary action.
    case confirm(index: Int)
    /// "Saved" acknowledgment for the species at `index`, then back to its photo.
    case saved(index: Int)

    /// The stack index the page is about, nil on the root.
    public var index: Int? {
        switch self {
        case .listening: nil
        case .photo(let index), .description(let index), .confirm(let index), .saved(let index): index
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

/// A button on a lens card, clicked through the Display rather than Inputs.
public enum LensButton: Sendable, Hashable {
    case save
    case cancel
}

/// What the adapter must do after an event, besides rendering the new page.
public enum LensEffect: Sendable, Equatable {
    /// The wearer confirmed this candidate: write a Sighting.
    case saveSighting(Candidate)
    /// Back on the root: end the glasses session.
    case endSession
}

/// Pure lens state machine (spec "Lens session"): folds `CandidateStack` updates and semantic input events into
/// the page to render and at most one side effect per event.
///
/// Page map (DECISIONS.md, "Lens UI"): listening ⇄ photo pages (swipe left/right), photo ⇄ description (swipe
/// down/up), photo → confirm (tap) → saved (tap or Save), confirm/saved → photo (swipe up), photo → listening
/// (swipe up). Back goes up one page and ends the session on the root. The stack never reorders and new species
/// append at the end, so an update never moves the page the wearer is on.
public struct LensStateMachine: Sendable, Equatable {
    public private(set) var page: LensPage = .listening
    /// The candidates the pages index into, in admission order.
    public private(set) var stack = CandidateStack()

    public init() {}

    /// The candidate the current page is about, nil on the listening page.
    public var currentCandidate: Candidate? {
        page.index.map { stack.candidates[$0] }
    }

    // MARK: - Stack

    /// Takes the latest stack. Returns true if anything the pages show changed. A stack that does not continue the
    /// current one (a new session) restarts on the listening page so no page can index past the end.
    @discardableResult
    public mutating func update(with stack: CandidateStack) -> Bool {
        guard stack != self.stack else { return false }
        let continues = stack.count >= self.stack.count
            && zip(stack.candidates, self.stack.candidates).allSatisfy { $0.species == $1.species }
        self.stack = stack
        if !continues { page = .listening }
        return true
    }

    // MARK: - Gestures

    /// Applies a gesture to the current page. Gestures with no meaning on the current page are ignored.
    public mutating func apply(_ gesture: LensGesture) -> LensEffect? {
        switch (page, gesture) {
        case (.listening, .swipeLeft), (.listening, .swipeRight):
            if !stack.isEmpty { page = .photo(index: 0) }
        case (.listening, .back):
            return .endSession
        case (.listening, _):
            break

        case let (.photo(index), .swipeLeft):
            if index + 1 < stack.count { page = .photo(index: index + 1) }
        case let (.photo(index), .swipeRight):
            page = index == 0 ? .listening : .photo(index: index - 1)
        case let (.photo(index), .swipeDown):
            page = .description(index: index)
        case (.photo, .swipeUp), (.photo, .back):
            page = .listening
        case let (.photo(index), .tap):
            page = .confirm(index: index)

        case let (.description(index), .swipeUp), let (.description(index), .back):
            page = .photo(index: index)
        case (.description, _):
            break

        case (.confirm, .tap):
            // Save is the primary action (DECISIONS.md, "Lens UI"), so a tap saves. Whether hardware also delivers a
            // Select to Inputs when the Cancel button is focused is unknown until the on-glasses run (#9).
            return save()
        case let (.confirm(index), .swipeUp), let (.confirm(index), .back):
            page = .photo(index: index)
        case (.confirm, _):
            break

        case (.saved, .tap):
            break
        case let (.saved(index), _):
            page = .photo(index: index)
        }
        return nil
    }

    /// A click on one of the confirm page's buttons. Buttons on other pages do not exist, so clicks are ignored.
    public mutating func press(_ button: LensButton) -> LensEffect? {
        guard case .confirm(let index) = page else { return nil }
        switch button {
        case .save: return save()
        case .cancel: page = .photo(index: index); return nil
        }
    }

    /// The Saved acknowledgment has been shown long enough: back to the photo.
    public mutating func dismissSaved() {
        guard case .saved(let index) = page else { return }
        page = .photo(index: index)
    }

    private mutating func save() -> LensEffect? {
        guard case .confirm(let index) = page else { return nil }
        page = .saved(index: index)
        return .saveSighting(stack.candidates[index])
    }

}
