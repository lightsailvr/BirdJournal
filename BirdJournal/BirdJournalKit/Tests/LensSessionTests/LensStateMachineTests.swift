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
        if [.captureSaving, .captureCancel, .captureSaved, .captureNaming, .captureMatches, .captureAdded].contains(page) {
            // Up to the row, and a tap on it: the shutter.
            _ = machine.apply(.swipeUp)
            _ = machine.apply(.tap)
        }
        if page == .captureCancel { _ = machine.apply(.swipeDown) }
        if page == .captureSaved { _ = machine.captureSaved(1, dictation: false) }
        if [.captureNaming, .captureMatches, .captureAdded].contains(page) { _ = machine.captureSaved(1, dictation: true) }
        if [.captureMatches, .captureAdded].contains(page) { machine.matched("black phoebe", Fakes.matches, dictation: 1) }
        if page == .captureAdded {
            _ = machine.apply(.tap)
            machine.captureNamed(1, as: Fakes.namedPhoebe)
        }
        if case .problem(let problem) = page { machine.report(problem) }
        if case .friend(let banner) = page { machine.friendFound(banner, at: 0) }
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

        // While the photo is on its way: swipe right and Back return to the list (the photo is still saved); a tap does
        // nothing, so a tap doubled on the viewfinder never skips what comes next.
        Transition(.captureSaving, .tap, .captureSaving, .capturePhoto(2)),
        Transition(.captureSaving, .swipeLeft, .captureSaving),
        Transition(.captureSaving, .swipeRight, .list),
        Transition(.captureSaving, .swipeUp, .captureSaving),
        Transition(.captureSaving, .swipeDown, .captureCancel),
        Transition(.captureSaving, .back, .list),

        // "Stop sending?": a tap gives the photos up, and anything else goes back to them.
        Transition(.captureCancel, .tap, .list, .cancelCaptures),
        Transition(.captureCancel, .swipeLeft, .captureSaving),
        Transition(.captureCancel, .swipeRight, .captureSaving),
        Transition(.captureCancel, .swipeUp, .captureSaving),
        Transition(.captureCancel, .swipeDown, .captureSaving),
        Transition(.captureCancel, .back, .captureSaving),

        // "Photo saved. Name it on your phone.": a tap, swipe right and Back return to the list.
        Transition(.captureSaved, .tap, .list),
        Transition(.captureSaved, .swipeLeft, .captureSaved),
        Transition(.captureSaved, .swipeRight, .list),
        Transition(.captureSaved, .swipeUp, .captureSaved),
        Transition(.captureSaved, .swipeDown, .captureSaved),
        Transition(.captureSaved, .back, .list),

        // "Say the bird's name" (issue #194): a tap is "name it later", the saved page; swipe right and Back return to the
        // list, the photo saved all the same; the other swipes do nothing.
        Transition(.captureNaming, .tap, .captureSaved),
        Transition(.captureNaming, .swipeLeft, .captureNaming),
        Transition(.captureNaming, .swipeRight, .list),
        Transition(.captureNaming, .swipeUp, .captureNaming),
        Transition(.captureNaming, .swipeDown, .captureNaming),
        Transition(.captureNaming, .back, .list),

        // What was heard and the birds it may be, the first highlighted: a tap names the photo as it; down and up move the
        // highlight (checked in `choosingAMatch`); swipe right and Back return to the list, the photo still unnamed.
        Transition(.captureMatches, .tap, .captureMatches, .nameCapture(1, as: Fakes.matches[0])),
        Transition(.captureMatches, .swipeLeft, .captureMatches),
        Transition(.captureMatches, .swipeRight, .list),
        Transition(.captureMatches, .swipeUp, .captureMatches),
        Transition(.captureMatches, .swipeDown, .captureMatches),
        Transition(.captureMatches, .back, .list),

        // "Added": a tap, swipe right and Back return to the list.
        Transition(.captureAdded, .tap, .list),
        Transition(.captureAdded, .swipeLeft, .captureAdded),
        Transition(.captureAdded, .swipeRight, .list),
        Transition(.captureAdded, .swipeUp, .captureAdded),
        Transition(.captureAdded, .swipeDown, .captureAdded),
        Transition(.captureAdded, .back, .list),

        // A problem page over the list (the way back, issue #10): swipe right, Back and a tap return to the page it
        // covers; the other swipes stay on it.
        Transition(.problem(.noLocation), .swipeLeft, .problem(.noLocation)),
        Transition(.problem(.noLocation), .swipeRight, .list),
        Transition(.problem(.noLocation), .swipeUp, .problem(.noLocation)),
        Transition(.problem(.noLocation), .swipeDown, .problem(.noLocation)),
        Transition(.problem(.noLocation), .tap, .list),
        Transition(.problem(.noLocation), .back, .list),

        // A friend banner over the list (issue #67): a tap, swipe right and Back dismiss it; the other swipes stay.
        Transition(.friend(Fakes.mayasPhoebe), .swipeLeft, .friend(Fakes.mayasPhoebe)),
        Transition(.friend(Fakes.mayasPhoebe), .swipeRight, .list),
        Transition(.friend(Fakes.mayasPhoebe), .swipeUp, .friend(Fakes.mayasPhoebe)),
        Transition(.friend(Fakes.mayasPhoebe), .swipeDown, .friend(Fakes.mayasPhoebe)),
        Transition(.friend(Fakes.mayasPhoebe), .tap, .list),
        Transition(.friend(Fakes.mayasPhoebe), .back, .list),
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
        let pages: [LensPage] = [.list, .species(index: 1), .details(index: 1), .sounds(index: 1), .viewfinder(index: 1), .captureSaving, .captureSaved, .captureNaming, .captureMatches, .captureAdded, .problem(.noLocation), .friend(Fakes.mayasPhoebe)]
        for page in pages {
            for gesture in LensGesture.allCases {
                #expect(Self.transitions.contains { $0.from == page && $0.gesture == gesture }, "\(page) + \(gesture) is not in the table")
            }
        }
    }

    // MARK: - The list as a menu

    @Test("swipe down and up move the selection through the list and stop at its last row (above the first is the capture row)")
    func listSelection() {
        var machine = Self.machine(on: .list)
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

    @Test("swipes down, up and right on the list with an empty stack stay put (a tap opens the capture row, the only one)")
    func listWithoutSpecies() {
        var machine = LensStateMachine()
        for gesture in [LensGesture.swipeDown, .swipeUp, .swipeRight] {
            #expect(machine.apply(gesture) == nil)
            #expect(machine.page == .list)
            #expect(machine.selection == 0)
        }
    }

    // MARK: - Capture a sighting (issue #193)

    @Test("the capture row is highlighted on an empty list; with birds the highlight is on the first bird, and one swipe up reaches the row")
    func captureRowHighlight() {
        var machine = LensStateMachine()
        #expect(machine.isCaptureRowHighlighted, "the only row there is")

        machine.update(with: Self.chorus(at: 20), at: 20)
        #expect(!machine.isCaptureRowHighlighted, "the first bird takes the highlight, as before")
        #expect(machine.selection == 2)

        #expect(machine.apply(.swipeUp) == nil)
        #expect(machine.page == .list)
        #expect(machine.isCaptureRowHighlighted)
    }

    @Test("from the capture row a swipe down or right returns to the first bird, unpinned, and a swipe up stays; the birds' own rules are as they were")
    func captureRowLeave() {
        var machine = LensStateMachine()
        machine.update(with: Self.chorus(at: 20), at: 20)
        _ = machine.apply(.swipeUp)
        _ = machine.apply(.swipeUp)
        #expect(machine.isCaptureRowHighlighted, "nothing above it")

        _ = machine.apply(.swipeDown)
        #expect(!machine.isCaptureRowHighlighted)
        #expect(machine.selection == 2, "row one: the towhee, the newest caller")
        #expect(machine.pinnedSpecies == nil, "as before any swipe: the highlight follows row one")

        // Down pins the second bird; up from it is the first bird, not the capture row; up again is the row.
        _ = machine.apply(.swipeDown)
        #expect(machine.pinnedSpecies == Fakes.finch)
        _ = machine.apply(.swipeUp)
        #expect(machine.pinnedSpecies == Fakes.towhee)
        #expect(!machine.isCaptureRowHighlighted)
        _ = machine.apply(.swipeUp)
        #expect(machine.isCaptureRowHighlighted)
        #expect(machine.pinnedSpecies == nil, "the highlight is on no bird")

        #expect(machine.apply(.swipeRight) == nil)
        #expect(machine.page == .list)
        #expect(!machine.isCaptureRowHighlighted)
        #expect(machine.selection == 2)
    }

    @Test("the highlight stays on the capture row while birds arrive; the first bird of an empty list takes it; a new session starts on the first bird")
    func captureRowHolds() {
        var machine = LensStateMachine()
        _ = machine.apply(.swipeUp)
        machine.update(with: Fakes.stack(1), at: Fakes.quiet)
        #expect(!machine.isCaptureRowHighlighted, "highlighted only for want of a bird, not chosen")

        _ = machine.apply(.swipeUp)
        machine.update(with: Fakes.stack(3), at: Fakes.quiet)
        #expect(machine.isCaptureRowHighlighted)

        machine.update(with: CandidateStack(candidates: [Fakes.candidate(Fakes.towhee)]), at: Fakes.quiet)
        #expect(!machine.isCaptureRowHighlighted)
    }

    @Test("a tap or a swipe left on the highlighted capture row is the shutter: the photo is taken at once, with no viewfinder, on an empty list too, and adds nothing", arguments: [LensGesture.tap, .swipeLeft])
    func captureRowShoots(_ gesture: LensGesture) {
        var empty = LensStateMachine()
        #expect(empty.apply(gesture) == .capturePhoto(1))
        #expect(empty.page == .captureSaving)

        var machine = Self.machine(on: .list)
        #expect(machine.apply(gesture) == nil, "a bird has the highlight: the gesture opens it")
        #expect(machine.page == .species(index: 0))
        _ = machine.apply(.swipeRight)
        _ = machine.apply(.swipeUp)
        #expect(machine.apply(gesture) == .capturePhoto(1))
        #expect(machine.page == .captureSaving)
        #expect(machine.page.index == nil)
        #expect(machine.currentCandidate == nil)
        #expect(machine.savedIndices.isEmpty)
        // The page stays, and a tap on it takes another. (A press delivered twice is the adapter's to drop: it has
        // the clock.)
        #expect(machine.apply(.tap) == .capturePhoto(2))
        #expect(machine.page == .captureSaving)
        // With photos crossing the row leads back to the page and takes none.
        _ = machine.apply(.swipeRight)
        #expect(machine.page == .list)
        #expect(machine.apply(gesture) == nil)
        #expect(machine.page == .captureSaving)
    }

    @Test("a tap on the capture page takes another photo; the page counts them as they arrive, only the oldest is crossing, and it ends on how many were saved")
    func captureQueue() {
        var machine = Self.machine(on: .captureSaving)
        #expect(machine.captureBatch.showsShutter, "the mark of the tap")
        let ended = machine.shutterEnded()
        #expect(ended && !machine.captureBatch.showsShutter)
        #expect(machine.apply(.tap) == .capturePhoto(2))
        #expect(machine.captureBatch.taken == 2 && machine.captureBatch.pending == 2 && machine.captureBatch.showsShutter)
        let early = machine.captureTaken(2, sent: 0.5)
        #expect(!early, "only the oldest is crossing")
        _ = machine.captureTaken(1, sent: 0.5)
        #expect(machine.captureSaved(1, dictation: true) == nil, "no name is asked for with another still crossing")
        #expect(machine.page == .captureSaving)
        #expect(machine.captureBatch.saved == 1 && !machine.captureBatch.isCrossing && machine.captureBatch.tenthsSent == 0)
        _ = machine.captureSaved(2, dictation: false)
        #expect(machine.page == .captureSaved)
        #expect(machine.captureBatch.saved == 2 && machine.captureBatch.pending == 0)
        // The next photo starts the count again.
        _ = machine.apply(.tap)
        #expect(machine.apply(.tap) == .capturePhoto(3))
        #expect(machine.captureBatch.taken == 1 && machine.captureBatch.saved == 0)
    }

    @Test("swipe down on the capture page asks whether to stop: a swipe keeps sending, a tap gives the photos up and returns to the list, and a photo saved while it asks ends the question")
    func captureGivenUp() {
        var machine = Self.machine(on: .captureSaving)
        #expect(machine.apply(.swipeDown) == nil)
        #expect(machine.page == .captureCancel)
        #expect(machine.isCapturing)
        #expect(machine.apply(.swipeRight) == nil)
        #expect(machine.page == .captureSaving)
        _ = machine.apply(.swipeDown)
        #expect(machine.apply(.tap) == .cancelCaptures)
        #expect(machine.page == .list)
        #expect(machine.captureBatch.pending == 0)
        #expect(!machine.isCapturing)
        // Late news of a photo given up moves nothing, and the row takes a new photo.
        #expect(machine.captureSaved(1, dictation: false) == nil)
        #expect(machine.page == .list)
        #expect(machine.apply(.tap) == .capturePhoto(2))

        var asked = Self.machine(on: .captureCancel)
        _ = asked.captureSaved(1, dictation: false)
        #expect(asked.page == .captureSaved, "nothing is left to stop")
    }

    @Test("a capture has the camera through the wait for its photo and while the glasses listen for the name, and under a problem over the wait; not on the list, the saved page, the birds a name may be, or \"Added\"")
    func captureHasTheCamera() {
        for page in [LensPage.captureSaving, .captureCancel, .captureNaming] {
            var machine = Self.machine(on: page)
            #expect(machine.isCapturing, "\(page)")
            if page == .captureSaving {
                machine.report(.noLocation)
                #expect(machine.isCapturing, "a problem over the wait: the photo is still on its way")
            }
        }
        for page in [LensPage.list, .species(index: 1), .details(index: 1), .viewfinder(index: 1), .captureSaved, .captureMatches, .captureAdded] {
            #expect(!Self.machine(on: page).isCapturing, "\(page)")
        }
        // Off the wait, and after a photo that could not be taken: listening has the camera back.
        var left = Self.machine(on: .captureSaving)
        _ = left.apply(.swipeRight)
        #expect(!left.isCapturing)
        var failed = Self.machine(on: .captureSaving)
        failed.captureFailed(1)
        #expect(!failed.isCapturing)
    }

    @Test("a tap on the capture row takes the photo; the lens waits, says so once it is saved, and returns to the list with the capture row still highlighted")
    func captureSaves() {
        var machine = Self.machine(on: .list)
        _ = machine.apply(.swipeUp)
        #expect(machine.apply(.tap) == .capturePhoto(1))
        #expect(machine.page == .captureSaving)
        #expect(machine.captureSaved(1, dictation: false) == nil)
        #expect(machine.page == .captureSaved)
        #expect(machine.apply(.tap) == nil)
        #expect(machine.page == .list)
        #expect(machine.isCaptureRowHighlighted, "one tap from another photo of the same bird")
        #expect(machine.savedIndices.isEmpty, "a capture adds no bird")

        // The next photo is another capture, one tap away, and late news of the first does not end its wait.
        #expect(machine.apply(.tap) == .capturePhoto(2))
        _ = machine.captureSaved(1, dictation: false)
        #expect(machine.page == .captureSaving)
        _ = machine.captureSaved(2, dictation: false)
        #expect(machine.page == .captureSaved)
    }

    @Test("the glasses having the photo is told once, for the capture the lens waits for, and a new capture starts untaken")
    func captureIsTaken() {
        var machine = Self.machine(on: .captureSaving)
        #expect(!machine.captureIsTaken)
        let other = machine.captureTaken(7)
        #expect(!other, "not the capture the lens waits for")
        let told = machine.captureTaken(1)
        #expect(told)
        #expect(machine.captureIsTaken)
        let again = machine.captureTaken(1)
        #expect(!again, "told once")
        let half = machine.captureTaken(1, sent: 0.55)
        #expect(half && machine.captureTenthsSent == 5, "and again as each tenth of it crosses")
        let same = machine.captureTaken(1, sent: 0.58)
        #expect(!same)
        let back = machine.captureTaken(1, sent: 0.3)
        #expect(!back && machine.captureTenthsSent == 5, "never backwards")
        _ = machine.captureSaved(1, dictation: false)
        _ = machine.apply(.tap)
        #expect(machine.apply(.tap) == .capturePhoto(2))
        #expect(!machine.captureIsTaken && machine.captureTenthsSent == 0)
    }

    @Test("a photo saved after the wearer left the wait moves no page")
    func captureLeft() {
        var machine = Self.machine(on: .captureSaving)
        _ = machine.apply(.swipeRight)
        #expect(machine.page == .list)
        #expect(machine.isCaptureRowHighlighted)
        #expect(machine.captureSaved(1, dictation: true) == nil, "nobody is there to say a name")
        #expect(machine.page == .list)
    }

    @Test("a photo that could not be taken is a problem over the list, or over the page the wearer has moved on to")
    func captureFails() {
        var machine = Self.machine(on: .captureSaving)
        machine.captureFailed(1)
        #expect(machine.page == .problem(.photoNotTaken))
        _ = machine.apply(.swipeRight)
        #expect(machine.page == .list, "not back to a wait that is over")
        #expect(machine.isCaptureRowHighlighted)

        var away = Self.machine(on: .captureSaving)
        _ = away.apply(.swipeRight)
        _ = away.apply(.swipeDown)
        _ = away.apply(.tap)
        #expect(away.page == .species(index: 0))
        away.captureFailed(1)
        #expect(away.page == .problem(.photoNotTaken))
        _ = away.apply(.tap)
        #expect(away.page == .species(index: 0))

        // One of two could not be taken while the other is still crossing: the page counts it, with no problem page.
        var again = Self.machine(on: .captureSaving)
        #expect(again.apply(.tap) == .capturePhoto(2))
        again.captureFailed(1)
        #expect(again.page == .captureSaving)
        #expect(again.captureBatch.failed == 1 && again.captureBatch.pending == 1)
        _ = again.captureSaved(2, dictation: false)
        #expect(again.page == .captureSaved)
    }

    @Test("a problem over the wait for a photo: the saved page is there when the problem goes")
    func problemOverCapture() {
        var machine = Self.machine(on: .captureSaving)

        machine.report(.noLocation)
        #expect(machine.captureSaved(1, dictation: true) == nil, "no name is asked for under a problem")
        #expect(machine.page == .problem(.noLocation))
        _ = machine.apply(.swipeRight)
        #expect(machine.page == .captureSaved)
    }

    @Test("a friend's find is held on the wait for a photo and the pages after it, and shown back on the list", arguments: [LensPage.captureSaving, .captureSaved, .captureNaming, .captureMatches, .captureAdded])
    func bannerHeldDuringCapture(_ page: LensPage) {
        var machine = Self.machine(on: page)
        machine.friendFound(Fakes.mayasPhoebe, at: 10)
        #expect(machine.page == page)
        #expect(machine.heldBanner == Fakes.mayasPhoebe)
        _ = machine.apply(.swipeRight)
        #expect(machine.page == .friend(Fakes.mayasPhoebe))
        #expect(machine.pageUnderBanner == .list)
        _ = machine.apply(.tap)
        #expect(machine.page == .list)
    }

    @Test("the Add button does nothing on the capture pages, and a new session's stack restarts them on the list", arguments: [LensPage.captureSaving, .captureSaved, .captureNaming, .captureMatches, .captureAdded])
    func capturePagesIgnoreSaveAndRestart(_ page: LensPage) {
        var machine = Self.machine(on: page)
        #expect(machine.press(.save) == nil)
        #expect(machine.page == page)
        machine.update(with: Fakes.stack(3), at: Fakes.quiet + 1)
        #expect(machine.page == page, "birds heard meanwhile move nothing")
        machine.update(with: CandidateStack(candidates: [Fakes.candidate(Fakes.towhee)]), at: Fakes.quiet)
        #expect(machine.page == .list)
        #expect(machine.captureSaved(1, dictation: true) == nil, "news of the old session's photo")
        #expect(machine.heard("black", dictation: 1) == false)
        #expect(machine.matched("black phoebe", Fakes.matches, dictation: 1) == false)
        #expect(machine.captureNamed(1, as: Fakes.namedPhoebe) == false)
        #expect(machine.page == .list)
        #expect(machine.naming == nil)
    }

    // MARK: - Saying the bird's name (issue #194)

    @Test("once the photo is saved the lens asks for the bird's name and listens; the words show as they are heard")
    func asksForTheName() {
        var machine = Self.machine(on: .captureSaving)
        #expect(machine.captureSaved(1, dictation: true) == .listenForName(dictation: 1, capture: 1))
        #expect(machine.page == .captureNaming)
        #expect(machine.naming == LensNaming(capture: 1, dictation: 1))
        #expect(machine.heard("black", dictation: 1) == true)
        #expect(machine.heard("black pho", dictation: 1) == true)
        #expect(machine.naming?.heard == "black pho")
        #expect(machine.heard("black pho", dictation: 1) == false, "nothing new to show")
        #expect(machine.heard("house", dictation: 7) == false, "words of some other dictation")
        #expect(machine.naming?.heard == "black pho")
        #expect(machine.page == .captureNaming)
    }

    @Test("the final words bring the birds they may be, the first highlighted; swipes move the highlight over the birds, \"Say it again\" and \"Name it later\", and stop at the ends")
    func choosingAMatch() {
        var machine = Self.machine(on: .captureNaming)
        _ = machine.heard("black", dictation: 1)
        #expect(machine.matched("black phoebe", Fakes.matches, dictation: 1) == true)
        #expect(machine.page == .captureMatches)
        #expect(machine.naming?.heard == "black phoebe")
        #expect(machine.naming?.matches == Fakes.matches)
        #expect(machine.naming?.highlight == 0)
        #expect(machine.apply(.swipeUp) == nil)
        #expect(machine.naming?.highlight == 0)
        for row in 1...4 {
            #expect(machine.apply(.swipeDown) == nil)
            #expect(machine.naming?.highlight == row)
        }
        #expect(machine.naming?.choice == .later)
        _ = machine.apply(.swipeDown)
        #expect(machine.naming?.highlight == 4, "\"Name it later\" is the last row")
        _ = machine.apply(.swipeUp)
        #expect(machine.naming?.choice == .again)
        _ = machine.apply(.swipeUp)
        #expect(machine.naming?.choice == .match(Fakes.matches[2]))
        #expect(machine.page == .captureMatches)
        #expect(machine.matched("house finch", [], dictation: 1) == false, "the dictation is over: nothing more is taken from it")
        #expect(machine.heard("house", dictation: 1) == false)
        #expect(machine.naming?.heard == "black phoebe")
    }

    @Test("a tap on a bird names the photo as it; nothing moves until the sighting is written, then the lens says what it earned, and a tap returns to the list")
    func namesTheCapture() {
        var machine = Self.machine(on: .captureMatches)
        _ = machine.apply(.swipeDown)
        #expect(machine.apply(.tap) == .nameCapture(1, as: Fakes.matches[1]))
        #expect(machine.page == .captureMatches)
        // A second tap, a swipe: the bird is chosen, and is not chosen twice.
        for gesture in LensGesture.allCases {
            #expect(machine.apply(gesture) == nil)
            #expect(machine.page == .captureMatches)
        }
        #expect(machine.naming?.highlight == 1)
        #expect(machine.captureNamed(2, as: Fakes.namedPhoebe) == false, "some other capture")
        #expect(machine.captureNamed(1, as: Fakes.namedPhoebe) == true)
        #expect(machine.page == .captureAdded)
        #expect(machine.named == Fakes.namedPhoebe)
        #expect(machine.naming == nil)
        #expect(machine.savedIndices.isEmpty, "a seen bird is no row of the list")
        #expect(machine.apply(.tap) == nil)
        #expect(machine.page == .list)
        #expect(machine.isCaptureRowHighlighted)
    }

    @Test("a name that could not be written leaves the photo saved for the phone")
    func namingFails() {
        var machine = Self.machine(on: .captureMatches)
        _ = machine.apply(.tap)
        #expect(machine.captureNotNamed(2) == false)
        #expect(machine.captureNotNamed(1) == true)
        #expect(machine.page == .captureSaved)
        #expect(machine.naming == nil)
        #expect(machine.captureNamed(1, as: Fakes.namedPhoebe) == false)
        #expect(machine.page == .captureSaved)
    }

    // Review of #185, Q6: the phone named or deleted the photo while the lens showed the birds, and the tap on a bird ended
    // on "Photo saved. Name it on your phone.", which was no longer true.
    @Test("a bird tapped for a photo the phone has named or deleted meanwhile: the lens says there is nothing to name, over the list, and the way back is the list")
    func thePhotoIsGone() {
        var machine = Self.machine(on: .captureMatches)
        _ = machine.apply(.tap)
        #expect(machine.captureGone(2) == false, "some other capture")
        #expect(machine.page == .captureMatches)
        #expect(machine.captureGone(1) == true)
        #expect(machine.page == .problem(.photoGone))
        #expect(machine.naming == nil)
        #expect(machine.captureNamed(1, as: Fakes.namedPhoebe) == false, "nothing more is taken for that capture")
        #expect(machine.apply(.swipeRight) == nil)
        #expect(machine.page == .list, "not the saved page: there is no photo left to name on the phone")
        #expect(machine.isCaptureRowHighlighted)

        // With a problem page over the birds: this one takes its place, and the way back is the list all the same.
        var covered = Self.machine(on: .captureMatches)
        _ = covered.apply(.tap)
        covered.report(.connectionLost)
        #expect(covered.captureGone(1) == true)
        #expect(covered.page == .problem(.photoGone))
        _ = covered.apply(.tap)
        #expect(covered.page == .list)

        // No bird was chosen: nothing is gone that the lens was writing.
        var choosing = Self.machine(on: .captureMatches)
        #expect(choosing.captureGone(1) == false)
        #expect(choosing.page == .captureMatches)
    }

    // Review of #185, J19: one press can arrive twice (a click and a select), and the echo must not be the next page's tap.
    @Test("the pages whose own tap would undo the press that opened them say so: the viewfinder, \"Say the bird's name\", \"Photo saved\" and \"Added\"")
    func pagesThatGuardTheirTap() {
        let guarded: [LensPage] = [.viewfinder(index: 1), .captureCancel, .captureNaming, .captureSaved, .captureAdded]
        let open: [LensPage] = [.list, .species(index: 1), .details(index: 1), .sounds(index: 1), .captureSaving, .captureMatches, .problem(.noLocation), .friend(Fakes.mayasPhoebe)]
        #expect(guarded.filter(\.guardsItsTap) == guarded)
        #expect(open.filter(\.guardsItsTap) == [])
    }

    // Review of #185, J6: the run read the lens's list order by copying the renderer's rule.
    @Test("the species in the order the list shows them: calling first, then the most recently heard; the stack's own order until the order has caught up")
    func listedSpecies() {
        var machine = LensStateMachine()
        #expect(machine.listedSpecies.isEmpty)
        machine.update(with: Self.chorus(at: 100), at: 100)
        #expect(machine.listedSpecies == [Fakes.towhee, Fakes.finch, Fakes.phoebe])
        #expect(machine.listedSpecies == machine.order.listed(machine.stack).map { machine.stack.candidates[$0].species })
        // An order that has not seen the stack: the stack's own.
        #expect(SpeciesListOrder().listed(machine.stack) == [0, 1, 2])
    }

    @Test("\"Say it again\" listens again, with the words gone, and the first dictation's late words are not taken for the second's")
    func saysItAgain() {
        var machine = Self.machine(on: .captureMatches)
        for _ in 0..<3 { _ = machine.apply(.swipeDown) }
        #expect(machine.naming?.choice == .again)
        #expect(machine.apply(.tap) == .listenForName(dictation: 2, capture: 1))
        #expect(machine.page == .captureNaming)
        #expect(machine.naming == LensNaming(capture: 1, dictation: 2))
        #expect(machine.heard("black phoebe", dictation: 1) == false)
        #expect(machine.dictationEnded(1) == false)
        #expect(machine.page == .captureNaming)
        #expect(machine.matched("house finch", [Fakes.matches[1]] + Fakes.matches, dictation: 2) == true)
        #expect(machine.naming?.matches == [Fakes.matches[1], Fakes.matches[0], Fakes.matches[1]], "the three closest")
        #expect(machine.naming?.highlight == 0)
    }

    @Test("\"Name it later\" is the saved page: the photo waits on the phone")
    func namesItLater() {
        var machine = Self.machine(on: .captureMatches)
        for _ in 0..<4 { _ = machine.apply(.swipeDown) }
        #expect(machine.apply(.tap) == nil)
        #expect(machine.page == .captureSaved)
        #expect(machine.naming == nil)
        _ = machine.apply(.tap)
        #expect(machine.page == .list)
    }

    @Test("words no bird answers to say so and offer the same two ways on, \"Say it again\" highlighted")
    func noMatch() {
        var machine = Self.machine(on: .captureNaming)
        #expect(machine.matched("flibber jibbet", [], dictation: 1) == true)
        #expect(machine.page == .captureMatches)
        #expect(machine.naming?.matches == [])
        #expect(machine.naming?.choice == .again)
        #expect(machine.apply(.swipeUp) == nil)
        #expect(machine.naming?.choice == .again)
        _ = machine.apply(.swipeDown)
        #expect(machine.naming?.choice == .later)
        _ = machine.apply(.swipeDown)
        #expect(machine.naming?.choice == .later)
        _ = machine.apply(.swipeUp)
        #expect(machine.apply(.tap) == .listenForName(dictation: 2, capture: 1))
        #expect(machine.page == .captureNaming)
    }

    @Test("a dictation that ends with nothing to match (silence, an error, no speech on the glasses) falls back to the saved page")
    func dictationEnds() {
        var machine = Self.machine(on: .captureNaming)
        #expect(machine.dictationEnded(3) == false, "some other dictation")
        #expect(machine.page == .captureNaming)
        #expect(machine.dictationEnded(1) == true)
        #expect(machine.page == .captureSaved)
        #expect(machine.naming == nil)
        #expect(machine.heard("black", dictation: 1) == false)
        #expect(machine.matched("black phoebe", Fakes.matches, dictation: 1) == false)
        #expect(machine.page == .captureSaved)

        // Once the birds are listed the dictation is over: its end changes nothing.
        var listed = Self.machine(on: .captureMatches)
        #expect(listed.dictationEnded(1) == false)
        #expect(listed.page == .captureMatches)
    }

    @Test("leaving \"Say the bird's name\" by a tap or a swipe right ends the dictation: its words are dropped", arguments: [LensGesture.tap, .swipeRight, .back])
    func leavesTheDictation(_ gesture: LensGesture) {
        var machine = Self.machine(on: .captureNaming)
        #expect(machine.apply(gesture) == nil)
        #expect(machine.page == (gesture == .tap ? .captureSaved : .list))
        #expect(machine.naming == nil)
        #expect(machine.matched("black phoebe", Fakes.matches, dictation: 1) == false)
        #expect(machine.page == (gesture == .tap ? .captureSaved : .list))
    }

    @Test("a problem over \"Say the bird's name\" ends the dictation, and the saved page is there when it goes; over the birds, they are still there")
    func problemOverNaming() {
        var machine = Self.machine(on: .captureNaming)
        machine.report(.connectionLost)
        #expect(machine.naming == nil)
        #expect(machine.heard("black", dictation: 1) == false)
        _ = machine.apply(.swipeRight)
        #expect(machine.page == .captureSaved)

        var listed = Self.machine(on: .captureMatches)
        listed.report(.noLocation)
        _ = listed.apply(.tap)
        #expect(listed.page == .captureMatches)
        #expect(listed.apply(.tap) == .nameCapture(1, as: Fakes.matches[0]))

        // A problem while the chosen name is being written: the lens says what it earned once the problem goes.
        listed.report(.noLocation)
        #expect(listed.captureNamed(1, as: Fakes.namedPhoebe) == false, "nothing the wearer sees changed")
        _ = listed.apply(.swipeRight)
        #expect(listed.page == .captureAdded)
    }

    @Test("the next photo is asked about afresh")
    func nextCapture() {
        var machine = Self.machine(on: .captureAdded)
        _ = machine.apply(.tap)
        #expect(machine.apply(.tap) == .capturePhoto(2))
        #expect(machine.captureSaved(2, dictation: true) == .listenForName(dictation: 2, capture: 2))
        #expect(machine.naming == LensNaming(capture: 2, dictation: 2))
        #expect(machine.named == nil)
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

    @Test("what an add earned is kept per species until the next add, and forgotten with the stack (issues #51, #132)")
    func earnedPatches() {
        var machine = Self.machine(on: .viewfinder(index: 1))
        _ = machine.apply(.tap)
        #expect(machine.earnedPatches.isEmpty, "the sighting is not written yet")

        let onStack = machine.earned(.newPatch, for: Fakes.finch)
        #expect(onStack)
        #expect(machine.earnedPatches == [1: .newPatch])
        #expect(machine.page == .details(index: 1), "no page of its own")

        _ = machine.apply(.tap)
        _ = machine.apply(.swipeDown)
        #expect(machine.earnedPatches.isEmpty, "Add another: nothing named until its own sighting is written")
        machine.earned(.seenAgain(count: 2), for: Fakes.finch)
        #expect(machine.earnedPatches == [1: .seenAgain(count: 2)])
        let offStack = machine.earned(.newPatch, for: Species(index: 9, scientificName: "Avis ignota", commonName: "Unknown", taxonomicClass: "Aves"))
        #expect(!offStack, "a species not on the stack")
        #expect(machine.earnedPatches == [1: .seenAgain(count: 2)])

        machine.update(with: CandidateStack(candidates: [Fakes.candidate(Fakes.towhee)]), at: Fakes.quiet)
        #expect(machine.earnedPatches.isEmpty)
    }

    @Test("after an add the details page's saved line names the new patch, sewn, or the count of a patch seen again (issues #132, #135)")
    func numberedSavedLine() {
        var machine = Self.machine(on: .viewfinder(index: 1))
        #expect(machine.apply(.tap) == .takePhoto(Fakes.candidate(Fakes.finch)))
        func savedLine() -> [LensElement] {
            LensCardRenderer.render(
                machine.page, stack: machine.stack, order: machine.order, selection: machine.selection, saved: machine.savedIndices,
                earned: machine.earnedPatches, profile: { _ in Fakes.phoebeProfile }
            ).elements.filter { if case .saved = $0 { true } else { false } }
        }
        #expect(savedLine() == [.saved("Added to my list")], "until the sighting is written")

        machine.earned(.newPatch, for: Fakes.finch)
        #expect(machine.page == .details(index: 1))
        #expect(savedLine() == [.saved("New patch · sewn")])

        _ = machine.apply(.tap)
        _ = machine.apply(.swipeDown)
        machine.earned(.seenAgain(count: 8), for: Fakes.finch)
        #expect(savedLine() == [.saved("Seen again · 8 times")], "another sighting of a patch the birder has")
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

    // MARK: - Friend banners (issue #67)

    @Test("a friend's find shows at once over the list and over a photo page, and dismissing returns there", arguments: [LensPage.list, .species(index: 1)])
    func bannerShowsOverListAndPhoto(_ page: LensPage) {
        var machine = Self.machine(on: page)
        machine.friendFound(Fakes.mayasPhoebe, at: 10)
        #expect(machine.page == .friend(Fakes.mayasPhoebe))
        #expect(machine.heldBanner == nil)
        #expect(machine.currentCandidate == nil)
        #expect(machine.apply(.tap) == nil)
        #expect(machine.page == page)
    }

    @Test("a friend's find is held on the viewfinder, a details page and a sounds page, and shown when the wearer returns to a photo page", arguments: [LensPage.viewfinder(index: 1), .details(index: 1), .sounds(index: 1)])
    func bannerHeld(_ page: LensPage) {
        var machine = Self.machine(on: page)
        machine.friendFound(Fakes.mayasPhoebe, at: 10)
        #expect(machine.page == page)
        #expect(machine.heldBanner == Fakes.mayasPhoebe)
        #expect(machine.heldBannerExpiry == 10 + LensStateMachine.bannerHoldLimit)
        // Off the viewfinder (a swipe adds the bird) lands on details: still held. Up is the photo page: shown.
        if case .viewfinder = page {
            #expect(machine.apply(.swipeLeft) == .saveSighting(Fakes.candidate(Fakes.finch)))
            #expect(machine.page == .details(index: 1))
            #expect(machine.heldBanner == Fakes.mayasPhoebe)
        }
        _ = machine.apply(page == .sounds(index: 1) ? .swipeDown : .swipeUp)
        #expect(machine.page == .friend(Fakes.mayasPhoebe))
        #expect(machine.heldBanner == nil)
        _ = machine.apply(.swipeRight)
        #expect(machine.page == .species(index: 1))
    }

    @Test("a banner held while a clip plays shows when the swipe that stops the clip lands on the list")
    func bannerHeldWhilePlaying() {
        var machine = Self.machine(on: .sounds(index: 0))
        guard case .playSound = machine.apply(.tap, sounds: Fakes.sounds) else { Issue.record("no clip started"); return }
        machine.friendFound(Fakes.mayasPhoebe, at: 10)
        #expect(machine.page == .sounds(index: 0))
        #expect(machine.apply(.swipeRight, sounds: Fakes.sounds) == .stopSound)
        #expect(machine.playing == nil)
        #expect(machine.page == .friend(Fakes.mayasPhoebe))
        _ = machine.apply(.tap)
        #expect(machine.page == .list)
    }

    @Test("a newer find replaces the banner showing, and the way back still leads to the covered page")
    func bannerReplacedWhileShowing() {
        var machine = Self.machine(on: .species(index: 2))
        machine.friendFound(Fakes.mayasPhoebe, at: 10)
        machine.friendFound(Fakes.samsOriole, at: 20)
        #expect(machine.page == .friend(Fakes.samsOriole))
        #expect(machine.heldBanner == nil)
        _ = machine.apply(.swipeRight)
        #expect(machine.page == .species(index: 2))
    }

    @Test("a newer find replaces the held one, restarting the hold; only the newer shows on return")
    func bannerReplacedWhileHeld() {
        var machine = Self.machine(on: .details(index: 1))
        machine.friendFound(Fakes.mayasPhoebe, at: 10)
        machine.friendFound(Fakes.samsOriole, at: 200)
        #expect(machine.heldBanner == Fakes.samsOriole)
        #expect(machine.heldBannerExpiry == 200 + LensStateMachine.bannerHoldLimit)
        #expect(machine.expireBanner(at: 10 + LensStateMachine.bannerHoldLimit + 1) == false)
        _ = machine.apply(.swipeUp)
        #expect(machine.page == .friend(Fakes.samsOriole))
        _ = machine.apply(.tap)
        #expect(machine.page == .species(index: 1))
        #expect(machine.heldBanner == nil)
    }

    @Test("the same find delivered twice is one banner: a repeat while held keeps the first arrival, and once dismissed it does not come back, even after another find")
    func bannerDuplicate() {
        var machine = Self.machine(on: .details(index: 1))
        machine.friendFound(Fakes.mayasPhoebe, at: 10)
        machine.friendFound(Fakes.mayasPhoebe, at: 100)
        #expect(machine.heldBannerExpiry == 10 + LensStateMachine.bannerHoldLimit)
        var showing = Self.machine(on: .list)
        showing.friendFound(Fakes.mayasPhoebe, at: 10)
        showing.friendFound(Fakes.mayasPhoebe, at: 11)
        #expect(showing.page == .friend(Fakes.mayasPhoebe))
        _ = showing.apply(.tap)
        #expect(showing.page == .list)
        showing.friendFound(Fakes.mayasPhoebe, at: 12)
        #expect(showing.page == .list)
        showing.friendFound(Fakes.samsOriole, at: 13)
        _ = showing.apply(.tap)
        showing.friendFound(Fakes.mayasPhoebe, at: 14)
        #expect(showing.page == .list)
        #expect(showing.heldBanner == nil)
    }

    @Test("a banner held for more than five minutes is dropped, and the wearer returns to the page itself")
    func bannerExpires() {
        var machine = Self.machine(on: .viewfinder(index: 1))
        machine.friendFound(Fakes.mayasPhoebe, at: 10)
        #expect(machine.expireBanner(at: 10 + LensStateMachine.bannerHoldLimit) == false, "exactly five minutes is not more than five")
        #expect(machine.heldBanner == Fakes.mayasPhoebe)
        let expired = machine.expireBanner(at: 10 + LensStateMachine.bannerHoldLimit + 0.5)
        #expect(expired)
        #expect(machine.heldBanner == nil)
        #expect(machine.heldBannerExpiry == nil)
        _ = machine.apply(.tap)
        _ = machine.apply(.swipeUp)
        #expect(machine.page == .species(index: 1))
    }

    @Test("a banner showing never expires; the wearer dismisses it")
    func shownBannerStays() {
        var machine = Self.machine(on: .list)
        machine.friendFound(Fakes.mayasPhoebe, at: 10)
        #expect(machine.expireBanner(at: 10_000) == false)
        #expect(machine.page == .friend(Fakes.mayasPhoebe))
    }

    @Test("a problem goes over a banner showing, which is held and back once the problem is dismissed")
    func problemOverBanner() {
        var machine = Self.machine(on: .species(index: 1))
        machine.friendFound(Fakes.mayasPhoebe, at: 10)
        machine.report(.connectionLost)
        #expect(machine.page == .problem(.connectionLost))
        #expect(machine.heldBanner == Fakes.mayasPhoebe)
        _ = machine.apply(.swipeRight)
        #expect(machine.page == .friend(Fakes.mayasPhoebe))
        _ = machine.apply(.swipeRight)
        #expect(machine.page == .species(index: 1))
    }

    @Test("a banner the wearer already had on the lens, pushed back by a problem, never expires: it is there when the problem goes, however late")
    func bannerPushedBackDoesNotExpire() {
        var machine = Self.machine(on: .list)
        machine.friendFound(Fakes.mayasPhoebe, at: 10)
        machine.report(.noLocation)
        #expect(machine.heldBannerExpiry == nil)
        #expect(machine.expireBanner(at: 10_000) == false)
        _ = machine.apply(.tap)
        #expect(machine.page == .friend(Fakes.mayasPhoebe))
    }

    @Test("a find arriving while a problem shows is held until the problem is dismissed")
    func bannerHeldUnderProblem() {
        var machine = Self.machine(on: .list)
        machine.report(.noLocation)
        machine.friendFound(Fakes.mayasPhoebe, at: 10)
        #expect(machine.page == .problem(.noLocation))
        _ = machine.apply(.tap)
        #expect(machine.page == .friend(Fakes.mayasPhoebe))
    }

    @Test("the Add button does nothing on a banner, and a species arriving appends under it")
    func bannerIgnoresSaveAndStack() {
        var machine = Self.machine(on: .species(index: 1), species: 2)
        machine.friendFound(Fakes.mayasPhoebe, at: 10)
        #expect(machine.press(.save) == nil)
        machine.update(with: Fakes.stack(3), at: Fakes.quiet)
        #expect(machine.page == .friend(Fakes.mayasPhoebe))
        _ = machine.apply(.tap)
        #expect(machine.page == .species(index: 1))
    }

    @Test("a new session restarts the pages on the list with the banner still showing")
    func bannerSurvivesNewSession() {
        var machine = Self.machine(on: .species(index: 2))
        machine.friendFound(Fakes.mayasPhoebe, at: 10)
        machine.update(with: CandidateStack(candidates: [Fakes.candidate(Fakes.towhee)]), at: 5)
        #expect(machine.page == .friend(Fakes.mayasPhoebe))
        _ = machine.apply(.tap)
        #expect(machine.page == .list)
    }
}
