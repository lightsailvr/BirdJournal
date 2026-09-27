import Identification
import Testing
@testable import LensSession

// Page map from DECISIONS.md, "Lens UI" (issue #24): a species list the app drives as a menu on the root, a photo
// page and a details page per species, with swipe right as the way back. Every (page, gesture) pair is listed in
// `transitions`, so a rule that goes missing fails a test rather than falling through to `default`.
@Suite("LensStateMachine")
struct LensStateMachineTests {
    /// A machine on `page` with `species` fake species in its stack, reached through gestures alone.
    static func machine(on page: LensPage, species: Int = 3) -> LensStateMachine {
        var machine = LensStateMachine()
        machine.update(with: Fakes.stack(species))
        if let index = page.index {
            for _ in 0..<index { _ = machine.apply(.swipeDown) }
            _ = machine.apply(.tap)
        }
        if case .details = page { _ = machine.apply(.swipeDown) }
        if case .problem(let problem) = page { machine.report(problem) }
        precondition(machine.page == page, "could not reach \(page)")
        return machine
    }

    @Test("starts on the species list with an empty stack, the first row selected and nothing saved")
    func initialState() {
        let machine = LensStateMachine()
        #expect(machine.page == .list)
        #expect(machine.stack.isEmpty)
        #expect(machine.selection == 0)
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

    /// Three species in the stack; the wearer is on the middle one where a page has a middle.
    static let transitions: [Transition] = [
        // The list with the first row selected: down and up move the selection (checked in `listSelection`); a tap
        // or swipe left opens the selected species; right has nothing before the list; Back ends the session.
        Transition(.list, .swipeLeft, .species(index: 0)),
        Transition(.list, .swipeRight, .list),
        Transition(.list, .swipeUp, .list),
        Transition(.list, .swipeDown, .list),
        Transition(.list, .tap, .species(index: 0)),
        Transition(.list, .back, .list, .endSession),

        // The photo page: down opens the details, up has nothing above; left is the next species and stops at the
        // end; right (and Back, on the mock) is back to the list; a tap does nothing, so no bird is added by accident.
        Transition(.species(index: 1), .swipeLeft, .species(index: 2)),
        Transition(.species(index: 1), .swipeRight, .list),
        Transition(.species(index: 1), .swipeUp, .species(index: 1)),
        Transition(.species(index: 1), .swipeDown, .details(index: 1)),
        Transition(.species(index: 1), .tap, .species(index: 1)),
        Transition(.species(index: 1), .back, .list),
        Transition(.species(index: 2), .swipeLeft, .species(index: 2)),

        // The details page: up is back to the photo, down has nothing below; left and right as on the photo page;
        // a tap is "Add to my list".
        Transition(.details(index: 1), .swipeLeft, .species(index: 2)),
        Transition(.details(index: 1), .swipeRight, .list),
        Transition(.details(index: 1), .swipeUp, .species(index: 1)),
        Transition(.details(index: 1), .swipeDown, .details(index: 1)),
        Transition(.details(index: 1), .tap, .details(index: 1), .saveSighting(Fakes.candidate(Fakes.finch))),
        Transition(.details(index: 1), .back, .list),
        Transition(.details(index: 2), .swipeLeft, .details(index: 2)),

        // A problem page over the list (the way back, issue #10): swipe right, Back and a tap return to the page it
        // covers; the other swipes stay on it.
        Transition(.problem(.noLocation), .swipeLeft, .problem(.noLocation)),
        Transition(.problem(.noLocation), .swipeRight, .list),
        Transition(.problem(.noLocation), .swipeUp, .problem(.noLocation)),
        Transition(.problem(.noLocation), .swipeDown, .problem(.noLocation)),
        Transition(.problem(.noLocation), .tap, .list),
        Transition(.problem(.noLocation), .back, .list),
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
        let pages: [LensPage] = [.list, .species(index: 1), .details(index: 1), .problem(.noLocation)]
        for page in pages {
            for gesture in LensGesture.allCases {
                #expect(Self.transitions.contains { $0.from == page && $0.gesture == gesture }, "\(page) + \(gesture) is not in the table")
            }
        }
    }

    // MARK: - The list as a menu

    @Test("swipe down and up move the selection through the list and stop at its ends")
    func listSelection() {
        var machine = Self.machine(on: .list)
        #expect(machine.apply(.swipeUp) == nil)
        #expect(machine.selection == 0)
        _ = machine.apply(.swipeDown)
        _ = machine.apply(.swipeDown)
        #expect(machine.selection == 2)
        _ = machine.apply(.swipeDown)
        #expect(machine.selection == 2)
        #expect(machine.page == .list)
        _ = machine.apply(.swipeUp)
        #expect(machine.selection == 1)
    }

    @Test("a tap opens the selected species, and the list keeps the selection when the wearer comes back")
    func openSelected() {
        var machine = Self.machine(on: .list)
        _ = machine.apply(.swipeDown)
        #expect(machine.apply(.tap) == nil)
        #expect(machine.page == .species(index: 1))
        _ = machine.apply(.swipeDown)
        _ = machine.apply(.swipeRight)
        #expect(machine.page == .list)
        #expect(machine.selection == 1)
    }

    @Test("paging to the next species moves the selection with it")
    func nextSpeciesMovesSelection() {
        var machine = Self.machine(on: .details(index: 0))
        _ = machine.apply(.swipeLeft)
        #expect(machine.page == .species(index: 1))
        #expect(machine.selection == 1)
        _ = machine.apply(.swipeRight)
        #expect(machine.page == .list)
        #expect(machine.selection == 1)
    }

    @Test("gestures on the list with an empty stack stay put")
    func listWithoutSpecies() {
        var machine = LensStateMachine()
        for gesture in [LensGesture.swipeLeft, .tap, .swipeDown, .swipeUp] {
            #expect(machine.apply(gesture) == nil)
            #expect(machine.page == .list)
            #expect(machine.selection == 0)
        }
    }

    // MARK: - Saving

    @Test("a tap on the details page adds the species and marks it; a later tap adds it again")
    func tapSaves() {
        var machine = Self.machine(on: .details(index: 1))
        #expect(machine.apply(.tap) == .saveSighting(Fakes.candidate(Fakes.finch)))
        #expect(machine.savedIndices == [1])
        #expect(machine.page == .details(index: 1))
        // Saving again updates the sighting (spec user story 33); a press delivered twice is the adapter's to drop.
        #expect(machine.apply(.tap) == .saveSighting(Fakes.candidate(Fakes.finch)))
        #expect(machine.savedIndices == [1])
    }

    @Test("the Add to my list button saves like a tap, and only on a details page")
    func saveButton() {
        var machine = Self.machine(on: .details(index: 2))
        #expect(machine.press(.save) == .saveSighting(Fakes.candidate(Fakes.towhee)))
        #expect(machine.savedIndices == [2])
        #expect(machine.page == .details(index: 2))

        for page in [LensPage.list, .species(index: 0)] {
            machine = Self.machine(on: page)
            #expect(machine.press(.save) == nil)
            #expect(machine.savedIndices.isEmpty)
            #expect(machine.page == page)
        }
    }

    @Test("saved species stay saved while paging away and back")
    func savedSurvivesNavigation() {
        var machine = Self.machine(on: .details(index: 0))
        _ = machine.apply(.tap)
        _ = machine.apply(.swipeLeft)
        _ = machine.apply(.swipeRight)
        _ = machine.apply(.swipeUp)
        _ = machine.apply(.tap)
        #expect(machine.page == .species(index: 0))
        #expect(machine.savedIndices == [0])
    }

    // MARK: - Problems

    @Test("a problem covers the page the wearer is on, and the way back returns there with the selection kept")
    func problemCoversPage() {
        var machine = Self.machine(on: .details(index: 1))
        machine.report(.connectionLost)
        #expect(machine.page == .problem(.connectionLost))
        #expect(machine.page.index == nil)
        #expect(machine.currentCandidate == nil)
        #expect(machine.apply(.swipeRight) == nil)
        #expect(machine.page == .details(index: 1))
        #expect(machine.selection == 1)
    }

    @Test("a second problem replaces the first and the way back still leads to the covered page")
    func problemReplaced() {
        var machine = Self.machine(on: .species(index: 2))
        machine.report(.noLocation)
        machine.report(.connectionLost)
        #expect(machine.page == .problem(.connectionLost))
        _ = machine.apply(.back)
        #expect(machine.page == .species(index: 2))
    }

    @Test("the Add button does nothing on a problem page")
    func problemIgnoresSave() {
        var machine = Self.machine(on: .problem(.noLocation))
        #expect(machine.press(.save) == nil)
        #expect(machine.savedIndices.isEmpty)
        #expect(machine.page == .problem(.noLocation))
    }

    @Test("a species arriving while a problem shows appends without dismissing it")
    func problemSurvivesAppend() {
        var machine = Self.machine(on: .details(index: 1), species: 2)
        machine.report(.noLocation)
        let changed = machine.update(with: Fakes.stack(3))
        #expect(changed)
        #expect(machine.page == .problem(.noLocation))
        _ = machine.apply(.swipeRight)
        #expect(machine.page == .details(index: 1))
        #expect(machine.stack.count == 3)
    }

    @Test("a stack that is not a continuation drops the problem along with the page")
    func problemDroppedOnReplacedStack() {
        var machine = Self.machine(on: .problem(.connectionLost))
        _ = machine.update(with: CandidateStack(candidates: [Fakes.candidate(Fakes.towhee)]))
        #expect(machine.page == .list)
    }

    // MARK: - Stack updates

    @Test("a new species arriving appends and leaves the page and the selection alone", arguments: [
        LensPage.species(index: 1), .details(index: 1), .list,
    ])
    func appendKeepsPage(page: LensPage) {
        var machine = Self.machine(on: page, species: 2)
        let selection = machine.selection
        let changed = machine.update(with: Fakes.stack(3))
        #expect(changed)
        #expect(machine.page == page)
        #expect(machine.selection == selection)
        #expect(machine.stack.candidates.map(\.species) == Fakes.all)
    }

    @Test("a score change on the current species keeps the order, the page and the saved mark")
    func scoreUpdateKeepsOrder() {
        var machine = Self.machine(on: .details(index: 0), species: 3)
        _ = machine.apply(.tap)
        var candidates = Fakes.stack(3).candidates
        candidates[0].score = 0.1
        candidates[2].score = 0.99
        let changed = machine.update(with: CandidateStack(candidates: candidates))
        #expect(changed)
        #expect(machine.page == .details(index: 0))
        #expect(machine.savedIndices == [0])
        #expect(machine.stack.candidates.map(\.species) == Fakes.all)
        #expect(machine.stack.candidates[0].score == 0.1)
    }

    @Test("an identical stack reports no change")
    func unchangedStack() {
        var machine = Self.machine(on: .species(index: 0), species: 2)
        #expect(machine.update(with: Fakes.stack(2)) == false)
    }

    @Test("a stack that is not a continuation of the current one restarts on the list with nothing saved")
    func replacedStackResets() {
        var machine = Self.machine(on: .details(index: 2), species: 3)
        _ = machine.apply(.tap)
        let changed = machine.update(with: CandidateStack(candidates: [Fakes.candidate(Fakes.towhee)]))
        #expect(changed)
        #expect(machine.page == .list)
        #expect(machine.selection == 0)
        #expect(machine.savedIndices.isEmpty)
        #expect(machine.stack.count == 1)
    }

    @Test("the current candidate follows the page")
    func currentCandidate() {
        #expect(Self.machine(on: .list).currentCandidate == nil)
        #expect(Self.machine(on: .species(index: 2)).currentCandidate == Fakes.candidate(Fakes.towhee))
        #expect(Self.machine(on: .details(index: 1)).currentCandidate == Fakes.candidate(Fakes.finch))
    }
}
