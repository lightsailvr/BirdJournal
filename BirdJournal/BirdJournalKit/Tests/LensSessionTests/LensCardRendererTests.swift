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

    @Test("the photo page has the pack photo beside the common name, confidence and position")
    func photo() {
        let card = Self.render(.photo(index: 0))
        #expect(card.photo == LensImage(id: "sayornis-nigricans-1"))
        #expect(card.elements == [
            .heading("Black Phoebe"),
            .body("80% match"),
            .meta("1 of 3"),
        ])
    }

    @Test("every page but the photo page has no photo", arguments: pages.filter { if case .photo = $0 { false } else { true } })
    func noPhoto(page: LensPage) {
        #expect(Self.render(page).photo == nil)
    }

    @Test("a species outside the pack is still shown by name")
    func photoWithoutPack() {
        let card = Self.render(.photo(index: 1))
        #expect(card.photo == nil)
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

    @Test("a pack without size or habitat leaves that line out rather than an empty one")
    func noSizeOrHabitat() {
        var profile = Fakes.phoebeProfile
        profile.size = ""
        profile.habitat = ""
        let card = LensCardRenderer.render(.description(index: 0), stack: Self.stack) { _ in profile }
        #expect(card.elements == [.heading("Black Phoebe"), .body(profile.fieldMarks), .meta("Photo: J. Birder, CC BY")])
        profile.habitat = "Streams"
        let habitatOnly = LensCardRenderer.render(.description(index: 0), stack: Self.stack) { _ in profile }
        #expect(habitatOnly.elements[2] == .meta("Streams"))
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

    @Test("long size, habitat and credit lines are cut too, and the field marks get what is left")
    func longMetaLines() {
        let long = Array(repeating: "word", count: 30).joined(separator: " ")
        let profile = SpeciesProfile(photo: nil, fieldMarks: long, size: long, habitat: long, photoCredit: long)
        let card = LensCardRenderer.render(.description(index: 0), stack: Self.stack) { _ in profile }
        #expect(card.wordCount <= LensCardRenderer.wordBudget)
        guard case .meta(let credit) = card.elements[3] else { Issue.record("no credit line"); return }
        #expect(credit.hasSuffix("…"))
        #expect(credit.words == LensCardRenderer.metaLineBudget)
    }

    @Test("confidence rounds the session score to a whole percent")
    func confidence() {
        let stack = CandidateStack(candidates: [Fakes.candidate(Fakes.phoebe, score: 0.999), Fakes.candidate(Fakes.finch, score: 0.054)])
        #expect(LensCardRenderer.render(.photo(index: 0), stack: stack, profile: Self.profile).elements[1] == .body("100% match"))
        #expect(LensCardRenderer.render(.photo(index: 1), stack: stack, profile: Self.profile).elements[1] == .body("5% match"))
    }
}
