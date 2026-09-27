import Identification
import Testing
@testable import LensSession

// Page map from DECISIONS.md, "Lens UI" (issue #24): a species list on the root and one card per species, both
// paged by screenful. Every (page, gesture) pair is listed in `transitions`, so a rule that goes missing fails a
// test rather than falling through to `default`.
@Suite("LensStateMachine")
struct LensStateMachineTests {
    /// Screenfuls the current card is taken to have when a test does not say otherwise.
    static let screenfuls = 2

    /// A machine on `page` with `species` fake species in its stack, reached through gestures alone.
    static func machine(on page: LensPage, species: Int = 3) -> LensStateMachine {
        var machine = LensStateMachine()
        machine.update(with: Fakes.stack(species))
        if let index = page.index {
            for _ in 0...index { _ = machine.apply(.swipeLeft, screenfuls: screenfuls) }
        }
        for _ in 0..<page.screenful { _ = machine.apply(.swipeDown, screenfuls: screenfuls) }
        precondition(machine.page == page, "could not reach \(page)")
        return machine
    }

    @Test("starts on the species list with an empty stack and nothing saved")
    func initialState() {
        let machine = LensStateMachine()
        #expect(machine.page == .list(screenful: 0))
        #expect(machine.stack.isEmpty)
        #expect(machine.savedIndices.isEmpty)
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

    /// Three species in the stack, cards of two screenfuls; the wearer is on the middle one where a page has a middle.
    static let transitions: [Transition] = [
        // The list: left and right open the first species; down and up page its screenfuls; a tap is left to the
        // Display (rows are opened through `press`); Back on the root ends the session.
        Transition(.list(screenful: 0), .swipeLeft, .species(index: 0, screenful: 0)),
        Transition(.list(screenful: 0), .swipeRight, .species(index: 0, screenful: 0)),
        Transition(.list(screenful: 0), .swipeUp, .list(screenful: 0)),
        Transition(.list(screenful: 0), .swipeDown, .list(screenful: 1)),
        Transition(.list(screenful: 0), .tap, .list(screenful: 0)),
        Transition(.list(screenful: 0), .back, .list(screenful: 0), .endSession),
        Transition(.list(screenful: 1), .swipeUp, .list(screenful: 0)),
        Transition(.list(screenful: 1), .swipeDown, .list(screenful: 1)),
        Transition(.list(screenful: 1), .swipeLeft, .species(index: 0, screenful: 0)),
        Transition(.list(screenful: 1), .back, .list(screenful: 1), .endSession),

        // A species card: left and right page through the stack (each card opens on its first screenful) and right
        // past the first returns to the list; down and up page the card's screenfuls, and up from the first is back
        // to the list; a tap is "This is my bird" on any screenful; Back returns to the list.
        Transition(.species(index: 1, screenful: 0), .swipeLeft, .species(index: 2, screenful: 0)),
        Transition(.species(index: 1, screenful: 0), .swipeRight, .species(index: 0, screenful: 0)),
        Transition(.species(index: 1, screenful: 0), .swipeUp, .list(screenful: 0)),
        Transition(.species(index: 1, screenful: 0), .swipeDown, .species(index: 1, screenful: 1)),
        Transition(.species(index: 1, screenful: 0), .tap, .species(index: 1, screenful: 0), .saveSighting(Fakes.candidate(Fakes.finch))),
        Transition(.species(index: 1, screenful: 0), .back, .list(screenful: 0)),
        Transition(.species(index: 1, screenful: 1), .swipeLeft, .species(index: 2, screenful: 0)),
        Transition(.species(index: 1, screenful: 1), .swipeRight, .species(index: 0, screenful: 0)),
        Transition(.species(index: 1, screenful: 1), .swipeUp, .species(index: 1, screenful: 0)),
        Transition(.species(index: 1, screenful: 1), .swipeDown, .species(index: 1, screenful: 1)),
        Transition(.species(index: 1, screenful: 1), .tap, .species(index: 1, screenful: 1), .saveSighting(Fakes.candidate(Fakes.finch))),
        Transition(.species(index: 1, screenful: 1), .back, .list(screenful: 0)),
        Transition(.species(index: 2, screenful: 0), .swipeLeft, .species(index: 2, screenful: 0)),
        Transition(.species(index: 0, screenful: 1), .swipeRight, .list(screenful: 0)),
    ]

    @Test("every page and gesture pair lands on the expected page with the expected effect", arguments: transitions)
    func transition(_ transition: Transition) {
        var machine = Self.machine(on: transition.from)
        let effect = machine.apply(transition.gesture, screenfuls: Self.screenfuls)
        #expect(machine.page == transition.to)
        #expect(effect == transition.effect)
    }

    @Test("the table covers every page kind, first and later screenfuls, and every gesture")
    func tableIsComplete() {
        let pages: [LensPage] = [.list(screenful: 0), .species(index: 1, screenful: 0), .species(index: 1, screenful: 1)]
        for page in pages {
            for gesture in LensGesture.allCases {
                #expect(Self.transitions.contains { $0.from == page && $0.gesture == gesture }, "\(page) + \(gesture) is not in the table")
            }
        }
        for gesture in [LensGesture.swipeUp, .swipeDown] {
            #expect(Self.transitions.contains { $0.from == .list(screenful: 1) && $0.gesture == gesture })
        }
    }

    @Test("a card with one screenful does not page down, and the screenful never runs past the card")
    func screenfulsAreClamped() {
        var machine = Self.machine(on: .species(index: 0, screenful: 0))
        #expect(machine.apply(.swipeDown, screenfuls: 1) == nil)
        #expect(machine.page == .species(index: 0, screenful: 0))
        // A card that shrank (the wearer is past its end) comes back to its last screenful on the next page down.
        machine = Self.machine(on: .species(index: 0, screenful: 1))
        _ = machine.apply(.swipeDown, screenfuls: 1)
        #expect(machine.page == .species(index: 0, screenful: 0))
    }

    @Test("swiping on the list with an empty stack stays put")
    func listWithoutSpecies() {
        var machine = LensStateMachine()
        #expect(machine.apply(.swipeLeft, screenfuls: 1) == nil)
        #expect(machine.page == .list(screenful: 0))
        #expect(machine.apply(.swipeRight, screenfuls: 1) == nil)
        #expect(machine.page == .list(screenful: 0))
    }

    // MARK: - Saving

    @Test("a tap on a species card saves it and marks the card; a later tap saves it again")
    func tapSaves() {
        var machine = Self.machine(on: .species(index: 1, screenful: 0))
        #expect(machine.apply(.tap, screenfuls: 2) == .saveSighting(Fakes.candidate(Fakes.finch)))
        #expect(machine.savedIndices == [1])
        #expect(machine.page == .species(index: 1, screenful: 0))
        // Saving again updates the sighting (spec user story 33); a press delivered twice is the adapter's to drop.
        #expect(machine.apply(.tap, screenfuls: 2) == .saveSighting(Fakes.candidate(Fakes.finch)))
        #expect(machine.savedIndices == [1])
    }

    @Test("the This is my bird button saves like a tap, and only on its own card")
    func saveButton() {
        var machine = Self.machine(on: .species(index: 2, screenful: 1))
        #expect(machine.press(.save) == .saveSighting(Fakes.candidate(Fakes.towhee)))
        #expect(machine.savedIndices == [2])
        #expect(machine.page == .species(index: 2, screenful: 1))

        machine = Self.machine(on: .list(screenful: 0))
        #expect(machine.press(.save) == nil)
        #expect(machine.savedIndices.isEmpty)
        #expect(machine.page == .list(screenful: 0))
    }

    @Test("saved cards stay saved while paging away and back")
    func savedSurvivesNavigation() {
        var machine = Self.machine(on: .species(index: 0, screenful: 0))
        _ = machine.apply(.tap, screenfuls: 2)
        _ = machine.apply(.swipeLeft, screenfuls: 2)
        _ = machine.apply(.swipeRight, screenfuls: 2)
        #expect(machine.page == .species(index: 0, screenful: 0))
        #expect(machine.savedIndices == [0])
    }

    // MARK: - The list's rows

    @Test("tapping a row on the list opens that species' card on its first screenful")
    func openFromList() {
        var machine = Self.machine(on: .list(screenful: 1))
        #expect(machine.press(.open(index: 2)) == nil)
        #expect(machine.page == .species(index: 2, screenful: 0))
    }

    @Test("a row tap is ignored off the list and for an index past the stack")
    func openElsewhere() {
        var machine = Self.machine(on: .species(index: 0, screenful: 0))
        #expect(machine.press(.open(index: 2)) == nil)
        #expect(machine.page == .species(index: 0, screenful: 0))

        machine = Self.machine(on: .list(screenful: 0))
        #expect(machine.press(.open(index: 3)) == nil)
        #expect(machine.page == .list(screenful: 0))
    }

    // MARK: - Stack updates

    @Test("a new species arriving appends and leaves the page alone", arguments: [
        LensPage.species(index: 1, screenful: 1), .species(index: 1, screenful: 0), .list(screenful: 0), .list(screenful: 1),
    ])
    func appendKeepsPage(page: LensPage) {
        var machine = Self.machine(on: page, species: 2)
        let changed = machine.update(with: Fakes.stack(3))
        #expect(changed)
        #expect(machine.page == page)
        #expect(machine.stack.candidates.map(\.species) == Fakes.all)
    }

    @Test("a score change on the current species keeps the order, the page and the saved mark")
    func scoreUpdateKeepsOrder() {
        var machine = Self.machine(on: .species(index: 0, screenful: 0), species: 3)
        _ = machine.apply(.tap, screenfuls: 2)
        var candidates = Fakes.stack(3).candidates
        candidates[0].score = 0.1
        candidates[2].score = 0.99
        let changed = machine.update(with: CandidateStack(candidates: candidates))
        #expect(changed)
        #expect(machine.page == .species(index: 0, screenful: 0))
        #expect(machine.savedIndices == [0])
        #expect(machine.stack.candidates.map(\.species) == Fakes.all)
        #expect(machine.stack.candidates[0].score == 0.1)
    }

    @Test("an identical stack reports no change")
    func unchangedStack() {
        var machine = Self.machine(on: .species(index: 0, screenful: 0), species: 2)
        #expect(machine.update(with: Fakes.stack(2)) == false)
    }

    @Test("a stack that is not a continuation of the current one restarts on the list with nothing saved")
    func replacedStackResets() {
        var machine = Self.machine(on: .species(index: 2, screenful: 1), species: 3)
        _ = machine.apply(.tap, screenfuls: 2)
        let changed = machine.update(with: CandidateStack(candidates: [Fakes.candidate(Fakes.towhee)]))
        #expect(changed)
        #expect(machine.page == .list(screenful: 0))
        #expect(machine.savedIndices.isEmpty)
        #expect(machine.stack.count == 1)
    }

    @Test("the current candidate follows the page")
    func currentCandidate() {
        #expect(Self.machine(on: .list(screenful: 0)).currentCandidate == nil)
        #expect(Self.machine(on: .species(index: 2, screenful: 1)).currentCandidate == Fakes.candidate(Fakes.towhee))
    }
}
