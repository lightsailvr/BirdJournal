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

    static func render(_ page: LensPage, selection: Int = 0, saved: Set<Int> = []) -> LensCard {
        LensCardRenderer.render(page, stack: stack, selection: selection, saved: saved, profile: profile)
    }

    static let saveButton = LensElement.button(LensCardButton(label: "This is my bird", action: .save))
    static let hint = LensElement.meta("Tap: this is my bird · swipe right: all species")

    /// Every page kind, on a species with a profile (index 0) and one without (index 1).
    static let pages: [LensPage] = [.list, .species(index: 0), .species(index: 1)]

    @Test("every page renders screenfuls that each stay inside the word budget", arguments: pages)
    func budget(page: LensPage) {
        let card = Self.render(page)
        #expect(!card.screenfuls.isEmpty)
        for (position, screenful) in card.screenfuls.enumerated() {
            let words = screenful.wordCount
            #expect(words > 0)
            #expect(words <= LensCardRenderer.wordBudget, "\(page) screenful \(position) uses \(words) words")
        }
    }

    // MARK: - The list

    @Test("the list counts the species heard and has one row per species, newest last, with the selection marked")
    func list() {
        #expect(LensCardRenderer.render(.list, stack: CandidateStack(), selection: 0, saved: [], profile: Self.profile).screenfuls == [[
            .heading("No species yet"), .meta("Cards appear as birds call."),
        ]])
        #expect(LensCardRenderer.render(.list, stack: Fakes.stack(1), selection: 0, saved: [], profile: Self.profile).screenfuls[0][0] == .heading("1 species heard"))
        #expect(Self.render(.list, selection: 1).screenfuls == [[
            .heading("3 species heard"),
            .meta("Swipe down to choose, tap to open."),
            .list([
                LensListRow(index: 0, commonName: "Black Phoebe", confidence: "80%", hasPhoto: true, isSaved: false, isSelected: false),
                LensListRow(index: 1, commonName: "House Finch", confidence: "80%", hasPhoto: false, isSaved: false, isSelected: true),
                LensListRow(index: 2, commonName: "California Towhee", confidence: "80%", hasPhoto: false, isSaved: false, isSelected: false),
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
            let card = LensCardRenderer.render(.list, stack: stack, selection: selection, saved: [], profile: { _ in nil })
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

    // MARK: - Species cards

    @Test("a species card is the photo, the name with its match rate, the status strip and a hint, then the text, credit and button")
    func speciesCard() {
        let card = Self.render(.species(index: 0))
        #expect(card.photo == LensImage(id: "sayornis-nigricans-1"))
        #expect(card.screenfuls == [
            [
                .photo(LensImage(id: "sayornis-nigricans-1")),
                .title("Black Phoebe", detail: "80% match"),
                .status("3 species · 1 of 3"),
                Self.hint,
            ],
            [
                .body(Fakes.phoebeProfile.fieldMarks),
                .meta("Sparrow-sized · Streams, ponds, lawns"),
                .meta("Photo: J. Birder, CC BY"),
                Self.saveButton,
            ],
        ])
    }

    @Test("a saved species shows the saved mark in place of the button, on the strip and in the hint")
    func savedCard() {
        let card = Self.render(.species(index: 0), saved: [0, 2])
        #expect(card.screenfuls[0][2] == .status("3 species · 1 of 3 · Saved"))
        #expect(card.screenfuls[0].last == .meta("Saved ✓ · swipe right: all species"))
        #expect(card.screenfuls[1].last == .saved("Saved ✓"))
        #expect(!card.elements.contains(Self.saveButton))
    }

    @Test("a species outside the pack is still shown by name, with its scientific name as the text")
    func speciesWithoutPack() {
        let card = Self.render(.species(index: 1))
        #expect(card.photo == nil)
        #expect(card.screenfuls == [
            [.title("House Finch", detail: "80% match"), .status("3 species · 2 of 3"), Self.hint],
            [.body("Haemorhous mexicanus"), .meta("Not in your pack"), Self.saveButton],
        ])
    }

    @Test("a pack entry without a photo says so instead of a credit, and empty text falls back to the scientific name")
    func profileWithoutPhotoOrText() {
        let profile = SpeciesProfile(photo: nil, fieldMarks: "", size: "", habitat: "", photoCredit: "")
        let card = LensCardRenderer.render(.species(index: 0), stack: Self.stack, selection: 0, saved: []) { _ in profile }
        #expect(card.screenfuls == [
            [.title("Black Phoebe", detail: "80% match"), .status("3 species · 1 of 3"), Self.hint],
            [.body("Sayornis nigricans"), .meta("No photo in your pack"), Self.saveButton],
        ])
    }

    @Test("a pack with habitat but no size shows habitat alone")
    func habitatOnly() {
        var profile = Fakes.phoebeProfile
        profile.size = ""
        profile.habitat = "Streams"
        let card = LensCardRenderer.render(.species(index: 0), stack: Self.stack, selection: 0, saved: []) { _ in profile }
        #expect(card.screenfuls[1][1] == .meta("Streams"))
    }

    @Test("long field marks are cut so the text screenful fills the budget exactly")
    func longFieldMarks() {
        var profile = Fakes.phoebeProfile
        profile.fieldMarks = Array(repeating: "word", count: 80).joined(separator: " ")
        let card = LensCardRenderer.render(.species(index: 0), stack: Self.stack, selection: 0, saved: []) { _ in profile }
        #expect(card.screenfuls[1].wordCount == LensCardRenderer.wordBudget)
        guard case .body(let fieldMarks) = card.screenfuls[1][0] else { Issue.record("no field marks"); return }
        #expect(fieldMarks.hasSuffix("…"))
    }

    @Test("long size, habitat and credit lines are cut too, and the field marks get what is left")
    func longMetaLines() {
        let long = Array(repeating: "word", count: 30).joined(separator: " ")
        let profile = SpeciesProfile(photo: LensImage(id: "x"), fieldMarks: long, size: long, habitat: long, photoCredit: long)
        let card = LensCardRenderer.render(.species(index: 0), stack: Self.stack, selection: 0, saved: []) { _ in profile }
        #expect(card.screenfuls[1].wordCount <= LensCardRenderer.wordBudget)
        guard case .meta(let credit) = card.screenfuls[1][2] else { Issue.record("no credit line"); return }
        #expect(credit.hasSuffix("…"))
        #expect(credit.words == LensCardRenderer.metaLineBudget)
    }

    @Test("confidence rounds the session score to a whole percent")
    func confidence() {
        let stack = CandidateStack(candidates: [Fakes.candidate(Fakes.phoebe, score: 0.999), Fakes.candidate(Fakes.finch, score: 0.054)])
        #expect(LensCardRenderer.confidence(stack.candidates[0]) == "100% match")
        #expect(LensCardRenderer.render(.species(index: 1), stack: stack, selection: 0, saved: [], profile: Self.profile).screenfuls[0][0] == .title("House Finch", detail: "5% match"))
    }
}
