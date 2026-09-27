import Identification
import Testing
@testable import LensSession

// Spec "Card renderer" and user story 24 (no page over about forty words), issue #7.
@Suite("LensCardRenderer")
struct LensCardRendererTests {
    static let stack = Fakes.stack(3)

    static func profile(_ species: Species) -> SpeciesProfile? {
        species == Fakes.phoebe ? Fakes.phoebeProfile : nil
    }

    static func render(_ page: LensPage) -> LensCard {
        LensCardRenderer.render(page, stack: stack, profile: profile)
    }

    /// Every page kind, on a species with a profile (index 0) and one without (index 1).
    static let pages: [LensPage] = [
        .listening, .photo(index: 0), .photo(index: 1), .description(index: 0), .description(index: 1),
        .confirm(index: 0), .saved(index: 0),
    ]

    @Test("every page renders one card with content inside the word budget", arguments: pages)
    func budget(page: LensPage) {
        let card = Self.render(page)
        #expect(!card.elements.isEmpty)
        #expect(card.wordCount <= LensCardRenderer.wordBudget, "\(page) uses \(card.wordCount) words")
        #expect(card.wordCount > 0)
    }

    @Test("the listening page counts species heard")
    func listening() {
        #expect(LensCardRenderer.render(.listening, stack: CandidateStack(), profile: Self.profile).elements[1] == .body("No species yet"))
        #expect(LensCardRenderer.render(.listening, stack: Fakes.stack(1), profile: Self.profile).elements[1] == .body("1 species heard"))
        #expect(Self.render(.listening).elements == [
            .heading("Listening"), .body("3 species heard"), .meta("Swipe left to see them."),
        ])
    }

    @Test("the photo page leads with the pack photo, then the common name, confidence and position")
    func photo() {
        let card = Self.render(.photo(index: 0))
        #expect(card.layout == .photoBeside)
        #expect(card.elements == [
            .image(LensImage(id: "sayornis-nigricans-1")),
            .heading("Black Phoebe"),
            .body("80% match"),
            .meta("1 of 3"),
        ])
    }

    @Test("a species outside the pack is still shown by name")
    func photoWithoutPack() {
        let card = Self.render(.photo(index: 1))
        #expect(card.layout == .column)
        #expect(card.elements == [
            .heading("House Finch"),
            .body("80% match"),
            .meta("2 of 3 · no photo in your pack"),
        ])
        #expect(Self.render(.description(index: 1)).elements == [
            .heading("House Finch"),
            .body("Haemorhous mexicanus"),
            .meta("No description in your pack."),
        ])
    }

    @Test("the description page has field marks, size, habitat and a one-line credit")
    func description() {
        #expect(Self.render(.description(index: 0)).elements == [
            .heading("Black Phoebe"),
            .body(Fakes.phoebeProfile.fieldMarks),
            .meta("Sparrow-sized · Streams, ponds, lawns"),
            .meta("Photo: J. Birder, CC BY"),
        ])
    }

    @Test("long field marks are cut to keep the description inside the budget")
    func longFieldMarks() {
        var profile = Fakes.phoebeProfile
        profile.fieldMarks = Array(repeating: "word", count: 80).joined(separator: " ")
        let card = LensCardRenderer.render(.description(index: 0), stack: Self.stack) { _ in profile }
        #expect(card.wordCount == LensCardRenderer.wordBudget, "the field marks fill the budget exactly")
        guard case .body(let fieldMarks) = card.elements[1] else { Issue.record("no field marks"); return }
        #expect(fieldMarks.hasSuffix("…"))
    }

    @Test("the confirm page has Save as the primary button")
    func confirm() {
        let card = Self.render(.confirm(index: 0))
        #expect(card.elements.contains(.body("Black Phoebe")))
        #expect(card.elements.last == .buttons([
            LensCardButton(label: "Save", action: .save, isPrimary: true),
            LensCardButton(label: "Cancel", action: .cancel, isPrimary: false),
        ]))
    }

    @Test("the saved page acknowledges the species")
    func saved() {
        #expect(Self.render(.saved(index: 0)).elements == [
            .heading("Saved"), .body("Black Phoebe"), .meta("Swipe up to keep listening."),
        ])
    }

    @Test("confidence rounds the session score to a whole percent")
    func confidence() {
        #expect(LensCardRenderer.confidence(Fakes.candidate(Fakes.phoebe, score: 0.999)) == "100% match")
        #expect(LensCardRenderer.confidence(Fakes.candidate(Fakes.phoebe, score: 0.054)) == "5% match")
    }

    @Test("word limiting keeps whole words and marks the cut")
    func wordLimit() {
        #expect("one two three".limited(toWords: 5) == "one two three")
        #expect("one two three".limited(toWords: 2) == "one two…")
        #expect("one two three".limited(toWords: 0) == "")
        #expect("a  b\nc".words == 3)
    }
}
