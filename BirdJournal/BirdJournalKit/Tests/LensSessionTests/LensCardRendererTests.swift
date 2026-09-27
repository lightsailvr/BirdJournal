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

    static func render(_ page: LensPage, saved: Set<Int> = []) -> LensCard {
        LensCardRenderer.render(page, stack: stack, saved: saved, profile: profile)
    }

    static let saveButton = LensElement.button(LensCardButton(label: "This is my bird", action: .save))

    /// Every page kind, on a species with a profile (index 0) and one without (index 1).
    static let pages: [LensPage] = [.list(screenful: 0), .species(index: 0, screenful: 0), .species(index: 1, screenful: 0)]

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

    @Test("the list counts the species heard and has one row per species, newest last")
    func list() {
        #expect(LensCardRenderer.render(.list(screenful: 0), stack: CandidateStack(), saved: [], profile: Self.profile).screenfuls == [[
            .heading("No species yet"), .meta("Cards appear as birds call."),
        ]])
        #expect(LensCardRenderer.render(.list(screenful: 0), stack: Fakes.stack(1), saved: [], profile: Self.profile).screenfuls[0][0] == .heading("1 species heard"))
        #expect(Self.render(.list(screenful: 0)).screenfuls == [[
            .heading("3 species heard"),
            .meta("Tap a species, or swipe left."),
            .list([
                LensListRow(index: 0, commonName: "Black Phoebe", confidence: "80%", hasPhoto: true, isSaved: false),
                LensListRow(index: 1, commonName: "House Finch", confidence: "80%", hasPhoto: false, isSaved: false),
                LensListRow(index: 2, commonName: "California Towhee", confidence: "80%", hasPhoto: false, isSaved: false),
            ]),
        ]])
    }

    @Test("saved species are marked on the list")
    func listMarksSaved() {
        guard case .list(let rows) = Self.render(.list(screenful: 0), saved: [1]).screenfuls[0][2] else { Issue.record("no rows"); return }
        #expect(rows.map(\.isSaved) == [false, true, false])
    }

    @Test("a long list is split into screenfuls of rows so each stays inside the budget, later ones with a strip")
    func longList() {
        let species = (0..<14).map { Species(index: $0, scientificName: "Genus species\($0)", commonName: "Long Winded Bird Name \($0)", taxonomicClass: "Aves") }
        let stack = CandidateStack(candidates: species.map { Fakes.candidate($0) })
        let card = LensCardRenderer.render(.list(screenful: 0), stack: stack, saved: [], profile: { _ in nil })
        let rows = card.screenfuls.map { screenful -> Int in
            screenful.reduce(0) { count, element in
                if case .list(let rows) = element { count + rows.count } else { count }
            }
        }
        #expect(rows == [5, 5, 4], "five-word names: the first screenful also holds the heading and the hint, later ones a strip")
        #expect(card.screenfuls[1].first == .status("14 species heard · 2 of 3"))
        #expect(card.screenfuls[2].first == .status("14 species heard · 3 of 3"))
        #expect(card.screenfuls[1].count == 2, "later screenfuls hold the strip and rows only")
        for screenful in card.screenfuls {
            #expect(screenful.wordCount <= LensCardRenderer.wordBudget)
        }
        guard case .list(let last) = card.screenfuls[2][1] else { Issue.record("no rows"); return }
        #expect(last.map(\.index) == [10, 11, 12, 13])
    }

    @Test("a screenful is looked up by its page index, clamped to the card")
    func screenfulLookup() {
        let card = Self.render(.species(index: 0, screenful: 0))
        #expect(card.screenful(at: 0) == card.screenfuls[0])
        #expect(card.screenful(at: 1) == card.screenfuls[1])
        #expect(card.screenful(at: 7) == card.screenfuls[1])
        #expect(card.screenful(at: -1) == card.screenfuls[0])
        #expect(LensCard(screenfuls: []).screenful(at: 0) == [])
    }

    // MARK: - Species cards

    @Test("a species card is a status strip, the photo, the name with its match rate, then the strip, text, credit and button")
    func speciesCard() {
        let card = Self.render(.species(index: 0, screenful: 0))
        #expect(card.photo == LensImage(id: "sayornis-nigricans-1"))
        #expect(card.screenfuls == [
            [
                .status("3 species · 1 of 3"),
                .photo(LensImage(id: "sayornis-nigricans-1")),
                .title("Black Phoebe", detail: "80% match"),
                .meta("Tap: this is my bird · swipe down for more"),
            ],
            [
                .status("3 species · 1 of 3"),
                .body(Fakes.phoebeProfile.fieldMarks),
                .meta("Sparrow-sized · Streams, ponds, lawns"),
                .meta("Photo: J. Birder, CC BY"),
                Self.saveButton,
            ],
        ])
    }

    @Test("a saved species shows the saved mark in place of the button, and on the strip")
    func savedCard() {
        let card = Self.render(.species(index: 0, screenful: 1), saved: [0, 2])
        #expect(card.screenfuls[0][0] == .status("3 species · 1 of 3 · Saved"))
        #expect(card.screenfuls[0].last == .meta("Saved ✓ · swipe down for more"))
        #expect(card.screenfuls[1][0] == .status("3 species · 1 of 3 · Saved"))
        #expect(card.screenfuls[1].last == .saved("Saved ✓"))
        #expect(!card.elements.contains(Self.saveButton))
    }

    @Test("a species outside the pack is still shown by name, with its scientific name as the text")
    func speciesWithoutPack() {
        let card = Self.render(.species(index: 1, screenful: 0))
        #expect(card.photo == nil)
        #expect(card.screenfuls == [
            [.status("3 species · 2 of 3"), .title("House Finch", detail: "80% match"), .meta("Tap: this is my bird · swipe down for more")],
            [.status("3 species · 2 of 3"), .body("Haemorhous mexicanus"), .meta("Not in your pack"), Self.saveButton],
        ])
    }

    @Test("a pack entry without a photo says so instead of a credit, and empty text falls back to the scientific name")
    func profileWithoutPhotoOrText() {
        let profile = SpeciesProfile(photo: nil, fieldMarks: "", size: "", habitat: "", photoCredit: "")
        let card = LensCardRenderer.render(.species(index: 0, screenful: 0), stack: Self.stack, saved: []) { _ in profile }
        #expect(card.screenfuls == [
            [.status("3 species · 1 of 3"), .title("Black Phoebe", detail: "80% match"), .meta("Tap: this is my bird · swipe down for more")],
            [.status("3 species · 1 of 3"), .body("Sayornis nigricans"), .meta("No photo in your pack"), Self.saveButton],
        ])
    }

    @Test("a pack with habitat but no size shows habitat alone")
    func habitatOnly() {
        var profile = Fakes.phoebeProfile
        profile.size = ""
        profile.habitat = "Streams"
        let card = LensCardRenderer.render(.species(index: 0, screenful: 0), stack: Self.stack, saved: []) { _ in profile }
        #expect(card.screenfuls[1][2] == .meta("Streams"))
    }

    @Test("long field marks are cut so the text screenful fills the budget exactly")
    func longFieldMarks() {
        var profile = Fakes.phoebeProfile
        profile.fieldMarks = Array(repeating: "word", count: 80).joined(separator: " ")
        let card = LensCardRenderer.render(.species(index: 0, screenful: 0), stack: Self.stack, saved: []) { _ in profile }
        #expect(card.screenfuls[1].wordCount == LensCardRenderer.wordBudget)
        guard case .body(let fieldMarks) = card.screenfuls[1][1] else { Issue.record("no field marks"); return }
        #expect(fieldMarks.hasSuffix("…"))
    }

    @Test("long size, habitat and credit lines are cut too, and the field marks get what is left")
    func longMetaLines() {
        let long = Array(repeating: "word", count: 30).joined(separator: " ")
        let profile = SpeciesProfile(photo: LensImage(id: "x"), fieldMarks: long, size: long, habitat: long, photoCredit: long)
        let card = LensCardRenderer.render(.species(index: 0, screenful: 0), stack: Self.stack, saved: []) { _ in profile }
        #expect(card.screenfuls[1].wordCount <= LensCardRenderer.wordBudget)
        guard case .meta(let credit) = card.screenfuls[1][3] else { Issue.record("no credit line"); return }
        #expect(credit.hasSuffix("…"))
        #expect(credit.words == LensCardRenderer.metaLineBudget)
    }

    @Test("confidence rounds the session score to a whole percent")
    func confidence() {
        let stack = CandidateStack(candidates: [Fakes.candidate(Fakes.phoebe, score: 0.999), Fakes.candidate(Fakes.finch, score: 0.054)])
        #expect(LensCardRenderer.confidence(stack.candidates[0]) == "100% match")
        #expect(LensCardRenderer.render(.species(index: 1, screenful: 0), stack: stack, saved: [], profile: Self.profile).screenfuls[0][1] == .title("House Finch", detail: "5% match"))
    }
}
