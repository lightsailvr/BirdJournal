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

    static func render(_ page: LensPage, selection: Int = 0, saved: Set<Int> = []) -> LensCard {
        LensCardRenderer.render(page, stack: stack, order: quietOrder, selection: selection, saved: saved, profile: profile)
    }

    static func render(_ page: LensPage, stack: CandidateStack, at time: Double, selection: Int = 0, saved: Set<Int> = [], profile: @escaping (Species) -> SpeciesProfile? = profile) -> LensCard {
        var order = SpeciesListOrder()
        order.update(with: stack, at: time)
        return LensCardRenderer.render(page, stack: stack, order: order, selection: selection, saved: saved, profile: profile)
    }

    static let saveButton = LensElement.button(LensCardButton(label: "Add to my list", action: .save))
    static let hint = LensElement.meta("Swipe down for more information · swipe right: all species")

    /// Every page kind, on a species with a profile (index 0) and one without (index 1).
    static let pages: [LensPage] = [
        .list, .species(index: 0), .species(index: 1), .details(index: 0), .details(index: 1),
        .problem(.noLocation), .problem(.connectionLost),
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
        #expect(Self.render(.list, stack: CandidateStack(), at: Fakes.quiet).screenfuls == [[
            .heading("No species yet"), .meta("Cards appear as birds call."),
        ]])
        #expect(Self.render(.list, stack: Fakes.stack(1), at: Fakes.quiet).screenfuls[0][0] == .heading("1 species heard"))
        #expect(Self.render(.list, selection: 1).screenfuls == [[
            .heading("3 species heard"),
            .meta("Swipe down to choose, tap to open."),
            .list([
                LensListRow(index: 0, commonName: "Black Phoebe", confidence: "80%", hasPhoto: true, isSaved: false, isSelected: false, isCalling: false),
                LensListRow(index: 1, commonName: "House Finch", confidence: "80%", hasPhoto: false, isSaved: false, isSelected: true, isCalling: false),
                LensListRow(index: 2, commonName: "California Towhee", confidence: "80%", hasPhoto: false, isSaved: false, isSelected: false, isCalling: false),
            ]),
        ]])
    }

    @Test("saved species are marked on the list")
    func listMarksSaved() {
        guard case .list(let rows) = Self.render(.list, saved: [1]).screenfuls[0][2] else { Issue.record("no rows"); return }
        #expect(rows.map(\.isSaved) == [false, true, false])
    }

    @Test("a long list shows the page of rows holding the selection, and says which page it is")
    func longList() {
        let species = (0..<12).map { Species(index: $0, scientificName: "Genus species\($0)", commonName: "Winded Bird \($0)", taxonomicClass: "Aves") }
        let stack = CandidateStack(candidates: species.map { Fakes.candidate($0) })
        func rows(selection: Int) -> (hint: LensElement, indices: [Int], selected: [Int]) {
            let card = Self.render(.list, stack: stack, at: Fakes.quiet, selection: selection, profile: { _ in nil })
            #expect(card.screenfuls.count == 1)
            #expect(card.screenfuls[0].wordCount <= LensCardRenderer.wordBudget)
            guard case .list(let rows) = card.screenfuls[0][2] else { Issue.record("no rows"); return (card.screenfuls[0][1], [], []) }
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
        guard case .list(let rows) = card.screenfuls[0][2] else { Issue.record("no rows"); return }
        #expect(rows.map(\.index) == [0, 11, 10, 9, 8])
        #expect(rows.map(\.isCalling) == [true, false, false, false, false])
        #expect(rows.map(\.isSelected) == [false, true, false, false, false])
        #expect(card.screenfuls[0][1] == .meta("Swipe down to choose, tap to open. Page 1 of 3."))
        let second = Self.render(.list, stack: CandidateStack(candidates: candidates), at: 100, selection: 6, profile: { _ in nil })
        guard case .list(let secondRows) = second.screenfuls[0][2] else { Issue.record("no rows"); return }
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

    @Test("an added species shows the mark in place of the button and on the photo page's strip")
    func savedPages() {
        #expect(Self.render(.species(index: 0), saved: [0, 2]).elements[2] == .status("3 species · 1 of 3 · Added"))
        let details = Self.render(.details(index: 0), saved: [0, 2])
        #expect(details.elements.last == .saved("Added to my list ✓"))
        #expect(!details.elements.contains(Self.saveButton))
    }

    @Test("a species outside the pack is still shown by name, with its scientific name as the text")
    func speciesWithoutPack() {
        let photoPage = Self.render(.species(index: 1))
        #expect(photoPage.photo == nil)
        #expect(photoPage.elements == [.title("House Finch", detail: "80% match"), .status("3 species · 2 of 3"), Self.hint])
        #expect(Self.render(.details(index: 1)).elements == [
            .title("House Finch", detail: "80% match"), .passage("Haemorhous mexicanus"), .meta("Not in your pack"), Self.saveButton,
        ])
    }

    @Test("a pack entry without a photo says so instead of a credit, and empty text falls back to the scientific name")
    func profileWithoutPhotoOrText() {
        let profile = SpeciesProfile(photo: nil, fieldMarks: "", size: "", habitat: "", photoCredit: "")
        let card = Self.render(.details(index: 0), stack: Self.stack, at: Fakes.quiet) { _ in profile }
        #expect(card.elements == [
            .title("Black Phoebe", detail: "80% match"), .passage("Sayornis nigricans"), .meta("No photo in your pack"), Self.saveButton,
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
            .body("Species are not filtered by your region. Allow location for BirdJournal in Settings on the phone."),
            .meta("Swipe right to continue"),
        ])
        #expect(Self.render(.problem(.connectionLost)).elements == [
            .heading("Connection lost"),
            .body("The glasses were out of range. BirdJournal kept listening and is back on the lens."),
            .meta("Swipe right to continue"),
        ])
        #expect(Self.render(.problem(.noLocation)).photo == nil)
    }

    @Test("confidence rounds the session score to a whole percent")
    func confidence() {
        let stack = CandidateStack(candidates: [Fakes.candidate(Fakes.phoebe, score: 0.999), Fakes.candidate(Fakes.finch, score: 0.054)])
        #expect(LensCardRenderer.confidence(stack.candidates[0]) == "100% match")
        #expect(Self.render(.species(index: 1), stack: stack, at: Fakes.quiet).elements[0] == .title("House Finch", detail: "5% match"))
    }
}
