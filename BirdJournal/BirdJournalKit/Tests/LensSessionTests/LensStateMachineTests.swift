import Identification
import Testing
@testable import LensSession

// Page map from DECISIONS.md, "Lens UI", and the spec's "Inputs mapping" (issue #7). Every (page, gesture) pair is
// listed in `transitions`, so a rule that goes missing fails a test rather than falling through to `default`.
@Suite("LensStateMachine")
struct LensStateMachineTests {
    /// A machine on `page` with `species` fake species in its stack.
    static func machine(on page: LensPage, species: Int = 3) -> LensStateMachine {
        var machine = LensStateMachine()
        _ = machine.update(with: Fakes.stack(species))
        machine.jump(to: page)
        return machine
    }

    @Test("starts on the listening page with an empty stack")
    func initialState() {
        let machine = LensStateMachine()
        #expect(machine.page == .listening)
        #expect(machine.stack.isEmpty)
    }

    // MARK: - Every (page, gesture) pair

    struct Transition: CustomTestStringConvertible {
        let from: LensPage
        let gesture: LensGesture
        let to: LensPage
        let effect: LensEffect?

        init(_ from: LensPage, _ gesture: LensGesture, _ to: LensPage, _ effect: LensEffect? = nil) {
            self.from = from
            self.gesture = gesture
            self.to = to
            self.effect = effect
        }

        var testDescription: String { "\(from) + \(gesture) → \(to)\(effect.map { " + \($0)" } ?? "")" }
    }

    /// Three species in the stack; the wearer is on the middle one where a page has a middle.
    static let transitions: [Transition] = [
        // Listening: swipes open the first species; Back on the root ends the session.
        Transition(.listening, .swipeLeft, .photo(index: 0)),
        Transition(.listening, .swipeRight, .photo(index: 0)),
        Transition(.listening, .swipeUp, .listening),
        Transition(.listening, .swipeDown, .listening),
        Transition(.listening, .tap, .listening),
        Transition(.listening, .back, .listening, .endSession),

        // Photo: left and right page through the stack, down opens the description, up is back, tap confirms.
        Transition(.photo(index: 1), .swipeLeft, .photo(index: 2)),
        Transition(.photo(index: 1), .swipeRight, .photo(index: 0)),
        Transition(.photo(index: 1), .swipeUp, .listening),
        Transition(.photo(index: 1), .swipeDown, .description(index: 1)),
        Transition(.photo(index: 1), .tap, .confirm(index: 1)),
        Transition(.photo(index: 1), .back, .listening),
        Transition(.photo(index: 2), .swipeLeft, .photo(index: 2)),
        Transition(.photo(index: 0), .swipeRight, .listening),

        // Description: up and Back return to the photo; nothing else moves.
        Transition(.description(index: 1), .swipeLeft, .description(index: 1)),
        Transition(.description(index: 1), .swipeRight, .description(index: 1)),
        Transition(.description(index: 1), .swipeUp, .photo(index: 1)),
        Transition(.description(index: 1), .swipeDown, .description(index: 1)),
        Transition(.description(index: 1), .tap, .description(index: 1)),
        Transition(.description(index: 1), .back, .photo(index: 1)),

        // Confirm: tap is Save; up and Back cancel.
        Transition(.confirm(index: 1), .swipeLeft, .confirm(index: 1)),
        Transition(.confirm(index: 1), .swipeRight, .confirm(index: 1)),
        Transition(.confirm(index: 1), .swipeUp, .photo(index: 1)),
        Transition(.confirm(index: 1), .swipeDown, .confirm(index: 1)),
        Transition(.confirm(index: 1), .tap, .saved(index: 1), .saveSighting(Fakes.candidate(Fakes.finch))),
        Transition(.confirm(index: 1), .back, .photo(index: 1)),

        // Saved: any swipe or Back returns to the photo; a tap is ignored so a doubled Select cannot skip the page.
        Transition(.saved(index: 1), .swipeLeft, .photo(index: 1)),
        Transition(.saved(index: 1), .swipeRight, .photo(index: 1)),
        Transition(.saved(index: 1), .swipeUp, .photo(index: 1)),
        Transition(.saved(index: 1), .swipeDown, .photo(index: 1)),
        Transition(.saved(index: 1), .tap, .saved(index: 1)),
        Transition(.saved(index: 1), .back, .photo(index: 1)),
    ]

    @Test("every page and gesture pair lands on the expected page with the expected effect", arguments: transitions)
    func transition(_ transition: Transition) {
        var machine = Self.machine(on: transition.from)
        let effect = machine.apply(transition.gesture)
        #expect(machine.page == transition.to)
        #expect(effect == transition.effect)
    }

    @Test("the table covers every page kind and gesture")
    func tableIsComplete() {
        let pages: [LensPage] = [.listening, .photo(index: 1), .description(index: 1), .confirm(index: 1), .saved(index: 1)]
        for page in pages {
            for gesture in LensGesture.allCases {
                #expect(Self.transitions.contains { $0.from == page && $0.gesture == gesture }, "\(page) + \(gesture) is not in the table")
            }
        }
    }

    @Test("swiping on the listening page with an empty stack stays put")
    func listeningWithoutSpecies() {
        var machine = LensStateMachine()
        #expect(machine.apply(.swipeLeft) == nil)
        #expect(machine.page == .listening)
        #expect(machine.apply(.swipeRight) == nil)
        #expect(machine.page == .listening)
    }

    // MARK: - Buttons and the saved page

    @Test("the Save button on the confirm page saves; Cancel returns to the photo")
    func confirmButtons() {
        var machine = Self.machine(on: .confirm(index: 2))
        #expect(machine.press(.cancel) == nil)
        #expect(machine.page == .photo(index: 2))

        machine.jump(to: .confirm(index: 2))
        #expect(machine.press(.save) == .saveSighting(Fakes.candidate(Fakes.towhee)))
        #expect(machine.page == .saved(index: 2))
    }

    @Test("buttons are ignored off the confirm page")
    func buttonsElsewhere() {
        for page in [LensPage.listening, .photo(index: 0), .description(index: 0), .saved(index: 0)] {
            var machine = Self.machine(on: page)
            #expect(machine.press(.save) == nil)
            #expect(machine.page == page)
        }
    }

    @Test("the saved page returns to the photo once acknowledged, and only then")
    func savedDismissal() {
        var machine = Self.machine(on: .saved(index: 0))
        machine.dismissSaved()
        #expect(machine.page == .photo(index: 0))

        machine.jump(to: .description(index: 0))
        machine.dismissSaved()
        #expect(machine.page == .description(index: 0))
    }

    // MARK: - Stack updates

    @Test("a new species arriving on a photo page appends and leaves the page alone", arguments: [
        LensPage.photo(index: 1), .description(index: 1), .confirm(index: 1), .saved(index: 1), .listening,
    ])
    func appendKeepsPage(page: LensPage) {
        var machine = Self.machine(on: page, species: 2)
        let changed = machine.update(with: Fakes.stack(3))
        #expect(changed)
        #expect(machine.page == page)
        #expect(machine.stack.candidates.map(\.species) == Fakes.all)
    }

    @Test("a score change on the current species keeps the order and the page")
    func scoreUpdateKeepsOrder() {
        var machine = Self.machine(on: .photo(index: 0), species: 3)
        var candidates = Fakes.stack(3).candidates
        candidates[0].score = 0.1
        candidates[2].score = 0.99
        let changed = machine.update(with: CandidateStack(candidates: candidates))
        #expect(changed)
        #expect(machine.page == .photo(index: 0))
        #expect(machine.stack.candidates.map(\.species) == Fakes.all)
        #expect(machine.stack.candidates[0].score == 0.1)
    }

    @Test("an identical stack reports no change")
    func unchangedStack() {
        var machine = Self.machine(on: .photo(index: 0), species: 2)
        #expect(machine.update(with: Fakes.stack(2)) == false)
    }

    @Test("a stack that is not a continuation of the current one restarts on the listening page")
    func replacedStackResets() {
        var machine = Self.machine(on: .description(index: 2), species: 3)
        let changed = machine.update(with: CandidateStack(candidates: [Fakes.candidate(Fakes.towhee)]))
        #expect(changed)
        #expect(machine.page == .listening)
        #expect(machine.stack.count == 1)
    }

    @Test("the current candidate follows the page")
    func currentCandidate() {
        #expect(Self.machine(on: .listening).currentCandidate == nil)
        #expect(Self.machine(on: .photo(index: 2)).currentCandidate == Fakes.candidate(Fakes.towhee))
        #expect(Self.machine(on: .saved(index: 0)).currentCandidate == Fakes.candidate(Fakes.phoebe))
    }
}
