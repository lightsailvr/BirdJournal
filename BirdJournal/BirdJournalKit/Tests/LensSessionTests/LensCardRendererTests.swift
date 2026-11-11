import Identification
import Testing
@testable import LensSession

// Spec "Card renderer" and user story 24 (about forty words per screenful, issue #24: the budget is per screenful of
// a scrolling card, not per card).
@Suite("LensCardRenderer")
struct LensCardRendererTests {
    static let stack = Fakes.stack(3)

    static func profile(_ species: Species) -> SpeciesProfile? {
        species == Fakes.phoebe ? Fakes.phoebeProfile : nil
    }

    /// The fake stack's order at a quiet moment: admission order, nothing calling.
    static let quietOrder: SpeciesListOrder = {
        var order = SpeciesListOrder()
        order.update(with: stack, at: Fakes.quiet)
        return order
    }()

    static func render(_ page: LensPage, selection: Int = 0, captureSelected: Bool = false, saved: Set<Int> = [], naming: LensNaming? = nil, named: LensNamedCapture? = nil) -> LensCard {
        LensCardRenderer.render(page, stack: stack, order: quietOrder, selection: selection, captureSelected: captureSelected, saved: saved, naming: naming, named: named, profile: profile)
    }

    static func render(_ page: LensPage, stack: CandidateStack, at time: Double, selection: Int = 0, captureSelected: Bool = false, saved: Set<Int> = [], profile: @escaping (Species) -> SpeciesProfile? = profile) -> LensCard {
        var order = SpeciesListOrder()
        order.update(with: stack, at: time)
        return LensCardRenderer.render(page, stack: stack, order: order, selection: selection, captureSelected: captureSelected, saved: saved, profile: profile)
    }

    /// The "Capture a sighting" row on top of the list (issue #193).
    static func captureRow(selected: Bool = false) -> LensElement {
        .capture(label: "Capture a sighting", isSelected: selected)
    }

    /// The bird rows of a list card.
    static func rows(_ card: LensCard) -> [LensListRow] {
        for element in card.elements {
            if case .list(let rows) = element { return rows }
        }
        return []
    }

    static let saveButton = LensElement.button(LensCardButton(label: "Add to my list", action: .save))
    static let hint = LensElement.meta("Swipe down for more information · swipe right: all species")

    /// Every page kind, on a species with a profile (index 0) and one without (index 1).
    static let pages: [LensPage] = [
        .list, .species(index: 0), .species(index: 1), .details(index: 0), .details(index: 1),
        .problem(.noLocation), .problem(.connectionLost), .friend(Fakes.mayasPhoebe),
        .captureViewfinder, .captureSaving, .captureSaved, .problem(.photoNotTaken), .problem(.photoGone),
    ]

    @Test("every page is one screenful inside the word budget; the details page has the larger one of its small-style text", arguments: pages)
    func budget(page: LensPage) {
        let card = Self.render(page)
        #expect(card.screenfuls.count == 1)
        #expect(card.wordCount > 0)
        if case .details = page {
            #expect(card.wordCount <= LensCardRenderer.detailsWordBudget, "\(page) uses \(card.wordCount) words")
        } else {
            #expect(card.wordCount <= LensCardRenderer.wordBudget, "\(page) uses \(card.wordCount) words")
        }
    }

    // MARK: - The list

    @Test("the list counts the species heard and has one row per species, newest last, with the selection marked")
    func list() {
        #expect(Self.render(.list, stack: CandidateStack(), at: Fakes.quiet, captureSelected: true).screenfuls == [[
            .heading("No species yet"), .meta("Birds appear as they call."), Self.captureRow(selected: true),
        ]])
        #expect(Self.render(.list, stack: Fakes.stack(1), at: Fakes.quiet).screenfuls[0][0] == .heading("1 species heard"))
        #expect(Self.render(.list, selection: 1).screenfuls == [[
            .heading("3 species heard"),
            .meta("Swipe down to choose, tap to open."),
            Self.captureRow(),
            .list([
                LensListRow(index: 0, commonName: "Black Phoebe", confidence: "80%", hasPhoto: true, isSaved: false, isSelected: false, isCalling: false),
                LensListRow(index: 1, commonName: "House Finch", confidence: "80%", hasPhoto: false, isSaved: false, isSelected: true, isCalling: false),
                LensListRow(index: 2, commonName: "California Towhee", confidence: "80%", hasPhoto: false, isSaved: false, isSelected: false, isCalling: false),
            ]),
        ]])
    }

    @Test("saved species are marked on the list")
    func listMarksSaved() {
        #expect(Self.rows(Self.render(.list, saved: [1])).map(\.isSaved) == [false, true, false])
    }

    @Test("a long list shows the page of rows holding the selection, and says which page it is")
    func longList() {
        let species = (0..<12).map { Species(index: $0, scientificName: "Genus species\($0)", commonName: "Winded Bird \($0)", taxonomicClass: "Aves") }
        let stack = CandidateStack(candidates: species.map { Fakes.candidate($0) })
        func rows(selection: Int) -> (hint: LensElement, indices: [Int], selected: [Int]) {
            let card = Self.render(.list, stack: stack, at: Fakes.quiet, selection: selection, profile: { _ in nil })
            #expect(card.screenfuls.count == 1)
            #expect(card.screenfuls[0].wordCount <= LensCardRenderer.wordBudget)
            let rows = Self.rows(card)
            return (card.screenfuls[0][1], rows.map(\.index), rows.filter(\.isSelected).map(\.index))
        }
        let first = rows(selection: 4)
        #expect(first.indices == [0, 1, 2, 3, 4] && first.selected == [4])
        #expect(first.hint == .meta("Swipe down to choose, tap to open. Page 1 of 3."))
        let second = rows(selection: 5)
        #expect(second.indices == [5, 6, 7, 8, 9] && second.selected == [5])
        #expect(second.hint == .meta("Swipe down to choose, tap to open. Page 2 of 3."))
        let last = rows(selection: 11)
        #expect(last.indices == [10, 11] && last.selected == [11])
    }

    // MARK: - Capture a sighting (issue #193)

    @Test("the capture row is above the first bird on every page of the list; when it has the highlight no bird does")
    func captureRow() {
        let chosen = Self.render(.list, selection: 0, captureSelected: true)
        #expect(chosen.elements[2] == Self.captureRow(selected: true))
        #expect(Self.rows(chosen).map(\.isSelected) == [false, false, false])

        let species = (0..<12).map { Species(index: $0, scientificName: "Genus species\($0)", commonName: "Winded Bird \($0)", taxonomicClass: "Aves") }
        let stack = CandidateStack(candidates: species.map { Fakes.candidate($0) })
        for selection in [0, 6, 11] {
            let card = Self.render(.list, stack: stack, at: Fakes.quiet, selection: selection, profile: { _ in nil })
            #expect(card.elements[2] == Self.captureRow(), "page of row \(selection)")
            #expect(Self.rows(card).filter(\.isSelected).map(\.index) == [selection])
            #expect(card.wordCount <= LensCardRenderer.wordBudget)
        }
        // With the highlight on the capture row the list shows its first page: the row is above the first bird.
        let top = Self.render(.list, stack: stack, at: Fakes.quiet, selection: 0, captureSelected: true, profile: { _ in nil })
        #expect(Self.rows(top).first?.index == 0)
    }

    @Test("the capture viewfinder is the camera's view, what it is for, and what a tap and a swipe do")
    func captureViewfinderPage() {
        #expect(Self.render(.captureViewfinder).elements == [
            .viewfinder,
            .heading("Capture a sighting"),
            .meta("Tap: take the photo · swipe right: back"),
        ])
    }

    @Test("after the tap the lens says the photo is being saved, then that it is saved and named on the phone")
    func capturedPages() {
        #expect(Self.render(.captureSaving).elements == [
            .heading("Saving the photo…"),
            .meta("Swipe right: all species"),
        ])
        #expect(Self.render(.captureSaved).elements == [
            .heading("Photo saved"),
            .body("Name it on your phone."),
            .meta("Tap or swipe right: all species"),
        ])
    }

    // MARK: - Saying the bird's name (issue #194)

    /// "Say the bird's name", with `heard` so far.
    static func listening(heard: String = "") -> LensNaming {
        var naming = LensNaming(capture: 1, dictation: 1)
        naming.heard = heard
        return naming
    }

    /// The birds' page for `heard`, the row `highlight` highlighted.
    static func listed(_ heard: String, _ matches: [LensNameMatch], highlight: Int = 0) -> LensNaming {
        var naming = listening(heard: heard)
        naming.matches = matches
        naming.highlight = highlight
        return naming
    }

    static let sayItAgain = "Say it again"
    static let nameItLater = "Name it later"

    @Test("\"Say the bird's name\" shows the photo, that the glasses are listening, then the words as they are heard, and what a tap does")
    func namingPage() {
        #expect(Self.render(.captureNaming, naming: Self.listening()).elements == [
            .heading("Say the bird's name"),
            .capturedPhoto,
            .meta("Listening…"),
            .meta("Tap: name it later on the phone"),
        ])
        #expect(Self.render(.captureNaming, naming: Self.listening(heard: "black pho")).elements == [
            .heading("Say the bird's name"),
            .capturedPhoto,
            .body("black pho"),
            .meta("Tap: name it later on the phone"),
        ])
    }

    @Test("the birds' page says what was heard and lists the birds it may be, \"New patch\" on those that would sew one, then \"Say it again\" and \"Name it later\"; one row is highlighted")
    func matchesPage() {
        #expect(Self.render(.captureMatches, naming: Self.listed("black phoebe", Fakes.matches)).elements == [
            .status("You said: black phoebe"),
            .choices([
                LensChoiceRow(label: "Black Phoebe", detail: "New patch", isSelected: true),
                LensChoiceRow(label: "Say's Phoebe", detail: nil, isSelected: false),
                LensChoiceRow(label: "Eastern Phoebe", detail: "New patch", isSelected: false),
                LensChoiceRow(label: Self.sayItAgain, detail: nil, isSelected: false),
                LensChoiceRow(label: Self.nameItLater, detail: nil, isSelected: false),
            ]),
            .meta("Swipe down: next · tap: choose"),
        ])
        for highlight in 0..<5 {
            let card = Self.render(.captureMatches, naming: Self.listed("black phoebe", Fakes.matches, highlight: highlight))
            guard case .choices(let rows) = card.elements[1] else {
                Issue.record("no rows")
                return
            }
            #expect(rows.map(\.isSelected) == (0..<5).map { $0 == highlight })
        }
    }

    @Test("words no bird answers to: the page says so, over the same two rows")
    func noMatchPage() {
        #expect(Self.render(.captureMatches, naming: Self.listed("flibber jibbet", [])).elements == [
            .status("You said: flibber jibbet"),
            .heading("No bird by that name"),
            .choices([
                LensChoiceRow(label: Self.sayItAgain, detail: nil, isSelected: true),
                LensChoiceRow(label: Self.nameItLater, detail: nil, isSelected: false),
            ]),
            .meta("Swipe down: next · tap: choose"),
        ])
    }

    @Test("\"Added\" names the bird, Seen, the set its patch is in, and what the add earned")
    func addedPage() {
        #expect(Self.render(.captureAdded, named: Fakes.namedPhoebe).elements == [
            .title("Black Phoebe", detail: "Seen"),
            .meta("Los Angeles"),
            .saved("Added"),
            .body("New patch, sewn on your phone."),
            .meta("Tap or swipe right: all species"),
        ])
        #expect(Self.render(.captureAdded, named: LensNamedCapture(commonName: "House Finch", place: nil, earned: .seenAgain(count: 3))).elements == [
            .title("House Finch", detail: "Seen"),
            .saved("Added"),
            .body("Seen again · 3 times"),
            .meta("Tap or swipe right: all species"),
        ])
    }

    @Test("a long ramble and three long names stay one screenful inside the word budget: what was heard is cut")
    func namingBudget() {
        let ramble = "well I think that one over there on the wire might just be a northern rough winged swallow or something like it"
        let long = [
            LensNameMatch(id: "a", commonName: "Northern Rough-winged Swallow", isNewPatch: true),
            LensNameMatch(id: "b", commonName: "Black-crowned Night Heron", isNewPatch: true),
            LensNameMatch(id: "c", commonName: "Greater White-fronted Goose", isNewPatch: true),
        ]
        for card in [
            Self.render(.captureNaming, naming: Self.listening(heard: ramble)),
            Self.render(.captureMatches, naming: Self.listed(ramble, long)),
            Self.render(.captureMatches, naming: Self.listed(ramble, [])),
            Self.render(.captureAdded, named: LensNamedCapture(commonName: "Northern Rough-winged Swallow", place: "San Francisco Bay Area", earned: .seenAgain(count: 12))),
        ] {
            #expect(card.screenfuls.count == 1)
            #expect(card.wordCount <= LensCardRenderer.wordBudget, "\(card.wordCount) words")
        }
        #expect(Self.render(.captureNaming, naming: Self.listening(heard: ramble)).elements[2] == .body("well I think that one over there on…"))
        #expect(Self.render(.captureMatches, naming: Self.listed(ramble, long)).elements[0] == .status("You said: well I think that one over…"))
    }

    @Test("a photo that was not taken is a problem page that says nothing was saved")
    func photoNotTaken() {
        #expect(Self.render(.problem(.photoNotTaken)).elements == [
            .heading("No photo taken"),
            .body("The camera was not ready, so nothing was saved. Open Capture a sighting again."),
            .meta("Swipe right to continue"),
        ])
    }

    // Review of #185, J5.
    @Test("the card of a machine is the card of its page and its state: the list with the capture row highlighted, a saved bird's details, the birds a name may be, and \"Added\"")
    func cardOfAMachine() {
        var machine = LensStateMachine()
        #expect(LensCardRenderer.render(machine, profile: Self.profile).elements == [.heading("No species yet"), .meta("Birds appear as they call."), Self.captureRow(selected: true)])

        machine.update(with: Fakes.stack(3), at: Fakes.quiet)
        _ = machine.apply(.swipeUp)
        #expect(LensCardRenderer.render(machine, profile: Self.profile).elements.contains(Self.captureRow(selected: true)))

        _ = machine.apply(.tap)
        _ = machine.apply(.tap)
        _ = machine.captureSaved(1, dictation: true)
        machine.matched("black phoebe", Fakes.matches, dictation: 1)
        _ = machine.apply(.swipeDown)
        #expect(LensCardRenderer.render(machine, profile: Self.profile) == Self.render(.captureMatches, naming: machine.naming))
        #expect(machine.naming?.highlight == 1)

        _ = machine.apply(.tap)
        machine.captureNamed(1, as: Fakes.namedPhoebe)
        #expect(LensCardRenderer.render(machine, profile: Self.profile) == Self.render(.captureAdded, named: Fakes.namedPhoebe))
    }

    @Test("a photo the phone named or deleted before the lens could is a problem page that says so, and not that the photo waits on the phone")
    func photoGone() {
        #expect(Self.render(.problem(.photoGone)).elements == [
            .heading("Nothing to name"),
            .body("That photo was named or deleted on your phone."),
            .meta("Swipe right to continue"),
        ])
    }

    // MARK: - Calling now (issue #42)

    /// Phoebe heard early, finch and towhee calling at `time`; the towhee is the newest caller, so row one.
    static func chorus(at time: Double) -> CandidateStack {
        CandidateStack(candidates: [
            Fakes.candidate(Fakes.phoebe, lastHeardAt: 3),
            Fakes.candidate(Fakes.finch, lastHeardAt: time - 3),
            Fakes.candidate(Fakes.towhee, lastHeardAt: time - 1),
        ])
    }

    @Test("the list shows the rows in list order, calling birds marked, with the highlight on the given species")
    func listInOrder() {
        let card = Self.render(.list, stack: Self.chorus(at: 20), at: 20, selection: 1)
        #expect(card.screenfuls == [[
            .heading("3 species heard"),
            .meta("Swipe down to choose, tap to open."),
            Self.captureRow(),
            .list([
                LensListRow(index: 2, commonName: "California Towhee", confidence: "80%", hasPhoto: false, isSaved: false, isSelected: false, isCalling: true),
                LensListRow(index: 1, commonName: "House Finch", confidence: "80%", hasPhoto: false, isSaved: false, isSelected: true, isCalling: true),
                LensListRow(index: 0, commonName: "Black Phoebe", confidence: "80%", hasPhoto: true, isSaved: false, isSelected: false, isCalling: false),
            ]),
        ]])
    }

    @Test("a long list pages by row position, so a pinned bird pushed down the list pages the view with it")
    func longListPagesByPosition() {
        let species = (0..<12).map { Species(index: $0, scientificName: "Genus species\($0)", commonName: "Winded Bird \($0)", taxonomicClass: "Aves") }
        // Admission order, but the first admitted is the one calling: it heads the list; the rest follow by recency.
        var candidates = species.map { Fakes.candidate($0, lastHeardAt: Double($0.index)) }
        candidates[0].lastHeardAt = 99
        let card = Self.render(.list, stack: CandidateStack(candidates: candidates), at: 100, selection: 11, profile: { _ in nil })
        let rows = Self.rows(card)
        #expect(rows.map(\.index) == [0, 11, 10, 9, 8])
        #expect(rows.map(\.isCalling) == [true, false, false, false, false])
        #expect(rows.map(\.isSelected) == [false, true, false, false, false])
        #expect(card.screenfuls[0][1] == .meta("Swipe down to choose, tap to open. Page 1 of 3."))
        let second = Self.render(.list, stack: CandidateStack(candidates: candidates), at: 100, selection: 6, profile: { _ in nil })
        let secondRows = Self.rows(second)
        #expect(secondRows.map(\.index) == [7, 6, 5, 4, 3])
        #expect(secondRows.map(\.isSelected) == [false, true, false, false, false])
        #expect(second.screenfuls[0][1] == .meta("Swipe down to choose, tap to open. Page 2 of 3."))
    }

    @Test("the photo page's strip says calling now for this bird, or names the bird calling now")
    func stripSaysWhoIsCalling() {
        let stack = Self.chorus(at: 20)
        #expect(Self.render(.species(index: 2), stack: stack, at: 20).elements[1] == .status("3 species · 3 of 3 · calling now"))
        #expect(Self.render(.species(index: 1), stack: stack, at: 20).elements[1] == .status("3 species · 2 of 3 · calling now"))
        #expect(Self.render(.species(index: 0), stack: stack, at: 20).elements[2] == .status("3 species · 1 of 3 · Now: California Towhee"))
        #expect(Self.render(.species(index: 0), stack: stack, at: 20, saved: [0]).elements[2] == .status("3 species · 1 of 3 · Added · Now: California Towhee"))
        #expect(Self.render(.species(index: 0), stack: stack, at: 60).elements[2] == .status("3 species · 1 of 3"), "nothing calling")
    }

    @Test("the details page gains a strip only while a bird is calling, inside its budget")
    func detailsStrip() {
        let stack = Self.chorus(at: 20)
        let calling = Self.render(.details(index: 1), stack: stack, at: 20)
        #expect(calling.elements[1] == .status("Calling now"))
        let other = Self.render(.details(index: 0), stack: stack, at: 20)
        #expect(other.elements[1] == .status("Now: California Towhee"))
        #expect(other.wordCount <= LensCardRenderer.detailsWordBudget)
        let quiet = Self.render(.details(index: 0), stack: stack, at: 60)
        #expect(quiet.elements[1] == .passage(Fakes.phoebeProfile.fieldMarks))

        var profile = Fakes.phoebeProfile
        profile.fieldMarks = Array(repeating: "word", count: 80).joined(separator: " ")
        let full = Self.render(.details(index: 0), stack: stack, at: 20) { _ in profile }
        #expect(full.wordCount == LensCardRenderer.detailsWordBudget)
    }

    // MARK: - Species cards

    @Test("the photo page is the photo, the name with its match rate, the status strip and the swipe-down hint")
    func photoPage() {
        let card = Self.render(.species(index: 0))
        #expect(card.photo == LensImage(id: "sayornis-nigricans-1"))
        #expect(card.elements == [
            .photo(LensImage(id: "sayornis-nigricans-1")),
            .title("Black Phoebe", detail: "80% match"),
            .status("3 species · 1 of 3"),
            Self.hint,
        ])
    }

    @Test("the details page is the name, the text, size and habitat, the credit and the Add button")
    func detailsPage() {
        let card = Self.render(.details(index: 0))
        #expect(card.photo == nil)
        #expect(card.elements == [
            .title("Black Phoebe", detail: "80% match"),
            .passage(Fakes.phoebeProfile.fieldMarks),
            .meta("Sparrow-sized · Streams, ponds, lawns"),
            .meta("Photo: J. Birder, CC BY"),
            Self.saveButton,
        ])
    }

    @Test("the viewfinder page is the camera's view, the name with its match rate, and what a tap and a swipe do")
    func viewfinderPage() {
        let card = Self.render(.viewfinder(index: 0))
        #expect(card.elements == [
            .viewfinder,
            .title("Black Phoebe", detail: "80% match"),
            .meta("Tap: take the photo · swipe: add without one"),
        ])
        #expect(card.wordCount <= LensCardRenderer.wordBudget)
    }

    @Test("the sounds page of a species without clips says so and points back to the photo")
    func soundsPageWithoutClips() {
        let card = Self.render(.sounds(index: 1))
        #expect(card.elements == [
            .title("House Finch", detail: "80% match"),
            .meta("No recordings on your phone · swipe down: photo"),
        ])
    }

    @Test("an added species shows the saved line and Add another in place of the button, and the mark on the photo page's strip")
    func savedPages() {
        #expect(Self.render(.species(index: 0), saved: [0, 2]).elements[2] == .status("3 species · 1 of 3 · Added"))
        let details = Self.render(.details(index: 0), saved: [0, 2])
        #expect(Array(details.elements.suffix(2)) == [.saved("Added to my list"), .button(LensCardRenderer.addAnotherButton)], "written, what it earned not yet known")
        #expect(!details.elements.contains(Self.saveButton))
    }

    @Test("once the sighting is written the saved line names what it earned: a new patch, sewn, or seen again with the count (issues #132, #135)")
    func earnedPatches() {
        func details(_ index: Int, earned: [Int: LensEarnedPatch], profile: @escaping (Species) -> SpeciesProfile? = Self.profile) -> LensCard {
            LensCardRenderer.render(.details(index: index), stack: Self.stack, order: Self.quietOrder, selection: 0, saved: [index], earned: earned, profile: profile)
        }
        let first = details(0, earned: [0: .newPatch])
        #expect(Array(first.elements.suffix(2)) == [.saved("New patch · sewn"), .button(LensCardRenderer.addAnotherButton)])
        #expect(details(0, earned: [0: .seenAgain(count: 3)]).elements.contains(.saved("Seen again · 3 times")))
        #expect(details(1, earned: [0: .seenAgain(count: 2), 1: .newPatch]).elements.contains(.saved("New patch · sewn")), "each species' own card")

        // The longest line still fits: the field marks give way to it.
        var long = Fakes.phoebeProfile
        long.fieldMarks = Array(repeating: "word", count: 80).joined(separator: " ")
        let full = details(0, earned: [0: .newPatch]) { _ in long }
        #expect(full.wordCount == LensCardRenderer.detailsWordBudget)
        #expect(full.elements.contains(.saved("New patch · sewn")))
        for index in 0..<3 {
            #expect(details(index, earned: [index: .newPatch]).wordCount <= LensCardRenderer.detailsWordBudget)
        }
    }

    @Test("a species outside the pack is still shown by name, with its scientific name as the text")
    func speciesWithoutPack() {
        let photoPage = Self.render(.species(index: 1))
        #expect(photoPage.photo == nil)
        #expect(photoPage.elements == [.title("House Finch", detail: "80% match"), .status("3 species · 2 of 3"), Self.hint])
        #expect(Self.render(.details(index: 1)).elements == [
            .title("House Finch", detail: "80% match"), .passage("Haemorhous mexicanus"), .meta("Not in your field guide"), Self.saveButton,
        ])
    }

    @Test("a pack entry without a photo says so instead of a credit, and empty text falls back to the scientific name")
    func profileWithoutPhotoOrText() {
        let profile = SpeciesProfile(photo: nil, fieldMarks: "", size: "", habitat: "", photoCredit: "")
        let card = Self.render(.details(index: 0), stack: Self.stack, at: Fakes.quiet) { _ in profile }
        #expect(card.elements == [
            .title("Black Phoebe", detail: "80% match"), .passage("Sayornis nigricans"), .meta("No photo on your phone"), Self.saveButton,
        ])
    }

    @Test("a pack with habitat but no size shows habitat alone")
    func habitatOnly() {
        var profile = Fakes.phoebeProfile
        profile.size = ""
        profile.habitat = "Streams"
        let card = Self.render(.details(index: 0), stack: Self.stack, at: Fakes.quiet) { _ in profile }
        #expect(card.elements[2] == .meta("Streams"))
    }

    @Test("long field marks are cut so the details page fills its budget exactly; forty pack words fit whole")
    func longFieldMarks() {
        var profile = Fakes.phoebeProfile
        profile.fieldMarks = Array(repeating: "word", count: 80).joined(separator: " ")
        let card = Self.render(.details(index: 0), stack: Self.stack, at: Fakes.quiet) { _ in profile }
        #expect(card.wordCount == LensCardRenderer.detailsWordBudget)
        guard case .passage(let fieldMarks) = card.elements[1] else { Issue.record("no field marks"); return }
        #expect(fieldMarks.hasSuffix("…"))

        profile.fieldMarks = Array(repeating: "word", count: 40).joined(separator: " ")
        let whole = Self.render(.details(index: 0), stack: Self.stack, at: Fakes.quiet) { _ in profile }
        #expect(whole.elements[1] == .passage(profile.fieldMarks), "the pack builder's forty-word field marks are never cut on the lens")
    }

    @Test("long size, habitat and credit lines are cut too, and the field marks get what is left")
    func longMetaLines() {
        let long = Array(repeating: "word", count: 30).joined(separator: " ")
        let profile = SpeciesProfile(photo: LensImage(id: "x"), fieldMarks: long, size: long, habitat: long, photoCredit: long)
        let card = Self.render(.details(index: 0), stack: Self.stack, at: Fakes.quiet) { _ in profile }
        #expect(card.wordCount <= LensCardRenderer.detailsWordBudget)
        guard case .meta(let credit) = card.elements[3] else { Issue.record("no credit line"); return }
        #expect(credit.hasSuffix("…"))
        #expect(credit.words == LensCardRenderer.metaLineBudget)
    }

    // MARK: - Problems

    @Test("a problem page names the problem, says what it means for the run, and gives the way back")
    func problemPages() {
        #expect(Self.render(.problem(.noLocation)).elements == [
            .heading("No location"),
            .body("Species are not filtered by place. Allow location for Featherguild in Settings on the phone."),
            .meta("Swipe right to continue"),
        ])
        #expect(Self.render(.problem(.connectionLost)).elements == [
            .heading("Connection lost"),
            .body("The glasses were out of range. Featherguild kept listening and is back on the lens."),
            .meta("Swipe right to continue"),
        ])
        #expect(Self.render(.problem(.noLocation)).photo == nil)
    }

    // MARK: - Friend banners (issue #67)

    @Test("a friend banner says who found what and where, and how to close it")
    func friendBanner() {
        #expect(Self.render(.friend(Fakes.mayasPhoebe)).elements == [
            .status("A friend's find"),
            .heading("Maya heard a Black Phoebe · Pasadena"),
            .meta("Tap or swipe right to close"),
        ])
        #expect(Self.render(.friend(Fakes.mayasPhoebe)).photo == nil)
    }

    @Test("the banner's line: saw for a bird seen, an before a vowel, a secret spot named as such, and no place at all")
    func friendBannerText() {
        #expect(Fakes.samsOriole.text == "Sam saw a Hooded Oriole")
        let owl = LensFriendBanner(id: "x", friendName: "A friend", method: .heard, speciesName: "Oak Titmouse", place: "a secret spot")
        #expect(owl.text == "A friend heard an Oak Titmouse · a secret spot")
        let empty = LensFriendBanner(id: "y", friendName: "Maya", method: .saw, speciesName: "Black Phoebe", place: "")
        #expect(empty.text == "Maya saw a Black Phoebe")
    }

    @Test("confidence rounds the session score to a whole percent")
    func confidence() {
        let stack = CandidateStack(candidates: [Fakes.candidate(Fakes.phoebe, score: 0.999), Fakes.candidate(Fakes.finch, score: 0.054)])
        #expect(LensCardRenderer.confidence(stack.candidates[0]) == "100% match")
        #expect(Self.render(.species(index: 1), stack: stack, at: Fakes.quiet).elements[0] == .title("House Finch", detail: "5% match"))
    }
}
