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
        machine.update(with: Fakes.stack(species), at: Fakes.quiet)
        if let index = page.index {
            for _ in 0..<index { _ = machine.apply(.swipeDown) }
            _ = machine.apply(.tap)
        }
        if case .details = page { _ = machine.apply(.swipeDown) }
        if case .sounds = page { _ = machine.apply(.swipeUp) }
        if case .viewfinder = page {
            _ = machine.apply(.swipeDown)
            _ = machine.apply(.tap)
        }
        if case .problem(let problem) = page { machine.report(problem) }
        precondition(machine.page == page, "could not reach \(page)")
        return machine
    }

    @Test("starts on the species list with an empty stack, the first row selected, unpinned, and nothing saved")
    func initialState() {
        let machine = LensStateMachine()
        #expect(machine.page == .list)
        #expect(machine.stack.isEmpty)
        #expect(machine.selection == 0)
        #expect(machine.pinnedSpecies == nil)
        #expect(machine.savedIndices.isEmpty)
    }

    // MARK: - The highlight follows the calling bird until pinned (issue #42)

    /// Phoebe heard early, finch and towhee calling at `time`; the towhee is the newest caller, so row one.
    static func chorus(at time: Double) -> CandidateStack {
        CandidateStack(candidates: [
            Fakes.candidate(Fakes.phoebe, lastHeardAt: 3),
            Fakes.candidate(Fakes.finch, lastHeardAt: time - 3),
            Fakes.candidate(Fakes.towhee, lastHeardAt: time - 1),
        ])
    }

    @Test("unpinned, the highlight sits on row one and follows the newest caller as the list moves")
    func unpinnedFollowsRowOne() {
        var machine = LensStateMachine()
        machine.update(with: Self.chorus(at: 20), at: 20)
        #expect(machine.order.indices == [2, 1, 0])
        #expect(machine.selection == 2)
        #expect(machine.pinnedSpecies == nil)

        // The finch goes quiet and the phoebe calls: the phoebe is row one and the highlight is on it.
        var candidates = Self.chorus(at: 20).candidates
        candidates[0].lastHeardAt = 29
        let changed = machine.update(with: CandidateStack(candidates: candidates), at: 30)
        #expect(changed)
        #expect(machine.order.indices == [0, 2, 1])
        #expect(machine.selection == 0)
        _ = machine.apply(.tap)
        #expect(machine.page == .species(index: 0))
    }

    @Test("a lapse with no stack change still reorders the list and the highlight")
    func lapseReorders() {
        var machine = LensStateMachine()
        machine.update(with: Self.chorus(at: 20), at: 20)
        #expect(machine.order.callingCount == 2)
        #expect(machine.order.nextLapse == 23)
        let changed = machine.update(with: Self.chorus(at: 20), at: 23)
        #expect(changed)
        #expect(machine.order.callingCount == 1)
        #expect(machine.update(with: Self.chorus(at: 20), at: 24) == false, "nothing lapsed since")
    }

    @Test("swipe down pins the highlight to that species, and it stays on the bird when the list moves under it")
    func swipeDownPins() {
        var machine = LensStateMachine()
        machine.update(with: Self.chorus(at: 20), at: 20)
        _ = machine.apply(.swipeDown)
        #expect(machine.pinnedSpecies == Fakes.finch)
        #expect(machine.selection == 1)

        // The phoebe starts calling and takes row one; the finch slides to row three and keeps the highlight.
        var candidates = Self.chorus(at: 20).candidates
        candidates[0].lastHeardAt = 21
        machine.update(with: CandidateStack(candidates: candidates), at: 22)
        #expect(machine.order.indices == [0, 1, 2])
        #expect(machine.selection == 1)
        _ = machine.apply(.swipeUp)
        #expect(machine.pinnedSpecies == Fakes.phoebe, "up moves the pin one row up in list order")
        #expect(machine.selection == 0)
    }

    @Test("swipe right on the list unpins and returns the highlight to row one")
    func swipeRightUnpins() {
        var machine = LensStateMachine()
        machine.update(with: Self.chorus(at: 20), at: 20)
        _ = machine.apply(.swipeDown)
        _ = machine.apply(.swipeDown)
        #expect(machine.pinnedSpecies == Fakes.phoebe)
        #expect(machine.apply(.swipeRight) == nil)
        #expect(machine.page == .list)
        #expect(machine.pinnedSpecies == nil)
        #expect(machine.selection == 2)
    }

    @Test("opening a card and coming back keeps the pin on that species; an unpinned tap stays unpinned")
    func cardVisitKeepsPin() {
        var machine = LensStateMachine()
        machine.update(with: Self.chorus(at: 20), at: 20)
        _ = machine.apply(.swipeDown)
        _ = machine.apply(.tap)
        #expect(machine.page == .species(index: 1))
        _ = machine.apply(.swipeRight)
        #expect(machine.page == .list)
        #expect(machine.pinnedSpecies == Fakes.finch)

        machine = LensStateMachine()
        machine.update(with: Self.chorus(at: 20), at: 20)
        _ = machine.apply(.tap)
        #expect(machine.page == .species(index: 2))
        _ = machine.apply(.swipeRight)
        #expect(machine.pinnedSpecies == nil)
        #expect(machine.selection == 2)
    }

    @Test("paging to the next species on a card pins the highlight to it")
    func nextSpeciesPins() {
        var machine = LensStateMachine()
        machine.update(with: Self.chorus(at: 20), at: 20)
        _ = machine.apply(.tap)
        #expect(machine.page == .species(index: 2))
        #expect(machine.apply(.swipeLeft) == nil, "the towhee is last in the stack")
        _ = machine.apply(.swipeRight)
        _ = machine.apply(.swipeDown)
        _ = machine.apply(.swipeDown)
        _ = machine.apply(.tap)
        #expect(machine.page == .species(index: 0))
        _ = machine.apply(.swipeLeft)
        #expect(machine.page == .species(index: 1))
        #expect(machine.pinnedSpecies == Fakes.finch)
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

        // The photo page: down opens the details, up the sounds; left is the next species and stops at the end;
        // right (and Back, on the mock) is back to the list; a tap does nothing (the band can read a swipe as one).
        Transition(.species(index: 1), .swipeLeft, .species(index: 2)),
        Transition(.species(index: 1), .swipeRight, .list),
        Transition(.species(index: 1), .swipeUp, .sounds(index: 1)),
        Transition(.species(index: 1), .swipeDown, .details(index: 1)),
        Transition(.species(index: 1), .tap, .species(index: 1)),
        Transition(.species(index: 1), .back, .list),
        Transition(.species(index: 2), .swipeLeft, .species(index: 2)),

        // The details page: up is back to the photo, down has nothing below; left and right as on the photo page;
        // a tap is "Add to my list", which opens the viewfinder.
        Transition(.details(index: 1), .swipeLeft, .species(index: 2)),
        Transition(.details(index: 1), .swipeRight, .list),
        Transition(.details(index: 1), .swipeUp, .species(index: 1)),
        Transition(.details(index: 1), .swipeDown, .details(index: 1)),
        Transition(.details(index: 1), .tap, .viewfinder(index: 1), .openViewfinder(Fakes.candidate(Fakes.finch))),
        Transition(.details(index: 1), .back, .list),
        Transition(.details(index: 2), .swipeLeft, .details(index: 2)),

        // The sounds page: down is back to the photo, up has nothing above; left and right as on the photo page;
        // a tap plays a clip (LensSoundTests), and does nothing for a species without any.
        Transition(.sounds(index: 1), .swipeLeft, .species(index: 2)),
        Transition(.sounds(index: 1), .swipeRight, .list),
        Transition(.sounds(index: 1), .swipeUp, .sounds(index: 1)),
        Transition(.sounds(index: 1), .swipeDown, .species(index: 1)),
        Transition(.sounds(index: 1), .tap, .sounds(index: 1)),
        Transition(.sounds(index: 1), .back, .list),

        // The viewfinder: a tap takes the photo and adds the bird; any swipe, or Back, adds it without one. Either
        // way the details page shows it added.
        Transition(.viewfinder(index: 1), .tap, .details(index: 1), .takePhoto(Fakes.candidate(Fakes.finch))),
        Transition(.viewfinder(index: 1), .swipeLeft, .details(index: 1), .saveSighting(Fakes.candidate(Fakes.finch))),
        Transition(.viewfinder(index: 1), .swipeRight, .details(index: 1), .saveSighting(Fakes.candidate(Fakes.finch))),
        Transition(.viewfinder(index: 1), .swipeUp, .details(index: 1), .saveSighting(Fakes.candidate(Fakes.finch))),
        Transition(.viewfinder(index: 1), .swipeDown, .details(index: 1), .saveSighting(Fakes.candidate(Fakes.finch))),
        Transition(.viewfinder(index: 1), .back, .details(index: 1), .saveSighting(Fakes.candidate(Fakes.finch))),

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
        let pages: [LensPage] = [.list, .species(index: 1), .details(index: 1), .sounds(index: 1), .viewfinder(index: 1), .problem(.noLocation)]
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

    @Test("a tap on the details page opens the viewfinder; a tap there adds the species with a photo and marks it; a later add takes another")
    func tapSaves() {
        var machine = Self.machine(on: .details(index: 1))
        #expect(machine.apply(.tap) == .openViewfinder(Fakes.candidate(Fakes.finch)))
        #expect(machine.savedIndices.isEmpty, "opening the viewfinder adds nothing yet")
        #expect(machine.page == .viewfinder(index: 1))
        #expect(machine.currentCandidate == Fakes.candidate(Fakes.finch))
        #expect(machine.apply(.tap) == .takePhoto(Fakes.candidate(Fakes.finch)))
        #expect(machine.savedIndices == [1])
        #expect(machine.page == .details(index: 1))
        // Adding again adds another sighting; a press delivered twice is the adapter's to drop.
        #expect(machine.apply(.tap) == .openViewfinder(Fakes.candidate(Fakes.finch)))
        #expect(machine.apply(.swipeRight) == .saveSighting(Fakes.candidate(Fakes.finch)))
        #expect(machine.savedIndices == [1])
        #expect(machine.page == .details(index: 1))
    }

    @Test("the card an add earned is kept per species until the next add, and forgotten with the stack (issue #51)")
    func earnedCards() {
        var machine = Self.machine(on: .viewfinder(index: 1))
        _ = machine.apply(.tap)
        #expect(machine.earnedCards.isEmpty, "the sighting is not written yet")

        let onStack = machine.earned(.legendary, for: Fakes.finch)
        #expect(onStack)
        #expect(machine.earnedCards == [1: .legendary])
        #expect(machine.page == .details(index: 1), "no page of its own")

        _ = machine.apply(.tap)
        _ = machine.apply(.swipeDown)
        #expect(machine.earnedCards.isEmpty, "Add another: no card named until its own sighting is written")
        machine.earned(.newCard(collectorNumber: "021/160"), for: Fakes.finch)
        #expect(machine.earnedCards == [1: .newCard(collectorNumber: "021/160")])
        let offStack = machine.earned(.newCard(collectorNumber: "Uncharted"), for: Species(index: 9, scientificName: "Avis ignota", commonName: "Unknown", taxonomicClass: "Aves"))
        #expect(!offStack, "a species not on the stack")
        #expect(machine.earnedCards == [1: .newCard(collectorNumber: "021/160")])

        machine.update(with: CandidateStack(candidates: [Fakes.candidate(Fakes.towhee)]), at: Fakes.quiet)
        #expect(machine.earnedCards.isEmpty)
    }

    @Test("after an add the details page's saved line names the card's collector number, or Uncharted (issue #54)")
    func numberedSavedLine() {
        var machine = Self.machine(on: .viewfinder(index: 1))
        #expect(machine.apply(.tap) == .takePhoto(Fakes.candidate(Fakes.finch)))
        func savedLine() -> [LensElement] {
            LensCardRenderer.render(
                machine.page, stack: machine.stack, order: machine.order, selection: machine.selection, saved: machine.savedIndices,
                earned: machine.earnedCards, profile: { _ in Fakes.phoebeProfile }
            ).elements.filter { if case .saved = $0 { true } else { false } }
        }
        #expect(savedLine() == [.saved("Added to my list", legendary: false)], "until the sighting is written")

        machine.earned(.newCard(collectorNumber: "021/160"), for: Fakes.finch)
        #expect(machine.page == .details(index: 1))
        #expect(savedLine() == [.saved("New card · 021/160", legendary: false)])

        _ = machine.apply(.tap)
        _ = machine.apply(.swipeDown)
        machine.earned(.newCard(collectorNumber: "Uncharted"), for: Fakes.finch)
        #expect(savedLine() == [.saved("New card · Uncharted", legendary: false)], "a sighting outside every set")

        _ = machine.apply(.tap)
        _ = machine.apply(.swipeDown)
        machine.earned(.legendary, for: Fakes.finch)
        #expect(savedLine() == [.saved("Your first House Finch", legendary: true)], "a Legendary card names the bird, not the number")
    }

    @Test("the Add to my list button opens the viewfinder like a tap, and only on a details page")
    func saveButton() {
        var machine = Self.machine(on: .details(index: 2))
        #expect(machine.press(.save) == .openViewfinder(Fakes.candidate(Fakes.towhee)))
        #expect(machine.page == .viewfinder(index: 2))
        // The button's click arriving again on the viewfinder (one press delivered twice) does nothing.
        #expect(machine.press(.save) == nil)
        #expect(machine.page == .viewfinder(index: 2))
        #expect(machine.savedIndices.isEmpty)

        for page in [LensPage.list, .species(index: 0), .sounds(index: 0)] {
            machine = Self.machine(on: page)
            #expect(machine.press(.save) == nil)
            #expect(machine.savedIndices.isEmpty)
            #expect(machine.page == page)
        }
    }

    @Test("saved species stay saved while paging away and back")
    func savedSurvivesNavigation() {
        var machine = Self.machine(on: .viewfinder(index: 0))
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
        let changed = machine.update(with: Fakes.stack(3), at: Fakes.quiet)
        #expect(changed)
        #expect(machine.page == .problem(.noLocation))
        _ = machine.apply(.swipeRight)
        #expect(machine.page == .details(index: 1))
        #expect(machine.stack.count == 3)
    }

    @Test("a stack that is not a continuation drops the problem along with the page")
    func problemDroppedOnReplacedStack() {
        var machine = Self.machine(on: .problem(.connectionLost))
        _ = machine.update(with: CandidateStack(candidates: [Fakes.candidate(Fakes.towhee)]), at: Fakes.quiet)
        #expect(machine.page == .list)
    }

    // MARK: - Stack updates

    @Test("a new species arriving appends and leaves the page and the selection alone", arguments: [
        LensPage.species(index: 1), .details(index: 1), .list,
    ])
    func appendKeepsPage(page: LensPage) {
        var machine = Self.machine(on: page, species: 2)
        let selection = machine.selection
        let changed = machine.update(with: Fakes.stack(3), at: Fakes.quiet)
        #expect(changed)
        #expect(machine.page == page)
        #expect(machine.selection == selection)
        #expect(machine.stack.candidates.map(\.species) == Fakes.all)
    }

    @Test("a score change on the current species keeps the order, the page and the saved mark")
    func scoreUpdateKeepsOrder() {
        var machine = Self.machine(on: .viewfinder(index: 0), species: 3)
        _ = machine.apply(.tap)
        var candidates = Fakes.stack(3).candidates
        candidates[0].score = 0.1
        candidates[2].score = 0.99
        let changed = machine.update(with: CandidateStack(candidates: candidates), at: Fakes.quiet)
        #expect(changed)
        #expect(machine.page == .details(index: 0))
        #expect(machine.savedIndices == [0])
        #expect(machine.stack.candidates.map(\.species) == Fakes.all)
        #expect(machine.stack.candidates[0].score == 0.1)
    }

    @Test("an identical stack reports no change")
    func unchangedStack() {
        var machine = Self.machine(on: .species(index: 0), species: 2)
        #expect(machine.update(with: Fakes.stack(2), at: Fakes.quiet) == false)
    }

    @Test("a stack that is not a continuation of the current one restarts on the list with nothing saved")
    func replacedStackResets() {
        var machine = Self.machine(on: .viewfinder(index: 2), species: 3)
        _ = machine.apply(.tap)
        let changed = machine.update(with: CandidateStack(candidates: [Fakes.candidate(Fakes.towhee)]), at: Fakes.quiet)
        #expect(changed)
        #expect(machine.page == .list)
        #expect(machine.selection == 0)
        #expect(machine.pinnedSpecies == nil)
        #expect(machine.savedIndices.isEmpty)
        #expect(machine.stack.count == 1)
    }

    @Test("the current candidate follows the page")
    func currentCandidate() {
        #expect(Self.machine(on: .list).currentCandidate == nil)
        #expect(Self.machine(on: .species(index: 2)).currentCandidate == Fakes.candidate(Fakes.towhee))
        #expect(Self.machine(on: .details(index: 1)).currentCandidate == Fakes.candidate(Fakes.finch))
        #expect(Self.machine(on: .sounds(index: 0)).currentCandidate == Fakes.candidate(Fakes.phoebe))
    }

    @Test("a problem over the viewfinder returns to it, and the add still waits for a tap or a swipe")
    func problemOverViewfinder() {
        var machine = Self.machine(on: .viewfinder(index: 1))
        machine.report(.connectionLost)
        #expect(machine.apply(.swipeRight) == nil)
        #expect(machine.page == .viewfinder(index: 1))
        #expect(machine.savedIndices.isEmpty)
        #expect(machine.apply(.tap) == .takePhoto(Fakes.candidate(Fakes.finch)))
    }
}
