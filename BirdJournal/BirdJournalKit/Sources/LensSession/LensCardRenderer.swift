import Identification

/// Maps a page and the stack to its card (spec "Card renderer", issue #24): the species list (count, one tappable
/// row per species) and the species card (status strip, photo, name and match rate; then the strip again, field
/// marks, size and habitat, credit and "This is my bird" or the saved mark). The page's screenful of the card is
/// what the lens shows. No screenful exceeds `wordBudget` words (spec user story 24): pack text is cut to fit,
/// field marks first, and long lists are split into screenfuls of rows, each taking as many rows as fit the budget.
public enum LensCardRenderer {
    public static let wordBudget = 40
    /// The most words a card spends on its size-and-habitat line and on its credit line.
    static let metaLineBudget = 8
    /// Words held back on later list screenfuls for their status strip ("14 species heard · 2 of 3").
    static let listStripBudget = 8
    static let saveButton = LensCardButton(label: "This is my bird", action: .save, isPrimary: true)

    public static func render(_ page: LensPage, stack: CandidateStack, saved: Set<Int>, profile: (Species) -> SpeciesProfile?) -> LensCard {
        switch page {
        case .list:
            return list(stack, saved: saved, profile: profile)
        case .species(let index, _):
            let candidate = stack.candidates[index]
            return species(candidate, position: index + 1, of: stack.count, isSaved: saved.contains(index), profile: profile(candidate.species))
        }
    }

    /// The session score as a percentage, e.g. "82% match".
    public static func confidence(_ candidate: Candidate) -> String {
        "\(percent(candidate)) match"
    }

    static func percent(_ candidate: Candidate) -> String {
        "\(Int((candidate.score * 100).rounded()))%"
    }

    static func list(_ stack: CandidateStack, saved: Set<Int>, profile: (Species) -> SpeciesProfile?) -> LensCard {
        let heading = switch stack.count {
        case 0: "No species yet"
        case 1: "1 species heard"
        default: "\(stack.count) species heard"
        }
        var first: [LensElement] = [
            .heading(heading),
            .meta(stack.isEmpty ? "Cards appear as birds call." : "Tap a species, or swipe left."),
        ]
        guard !stack.isEmpty else { return LensCard(screenfuls: [first]) }
        let rows = stack.candidates.enumerated().map { index, candidate in
            LensListRow(
                index: index,
                commonName: candidate.species.commonName,
                confidence: percent(candidate),
                hasPhoto: profile(candidate.species)?.photo != nil,
                isSaved: saved.contains(index)
            )
        }
        // Rows fill each screenful up to the budget; the first one also carries the heading and the hint, the later
        // ones a status strip saying where in the list they are.
        var pages: [[LensListRow]] = [[]]
        var words = first.reduce(0) { $0 + $1.words }
        for row in rows {
            let rowWords = row.commonName.words + row.confidence.words
            if !pages[pages.count - 1].isEmpty, words + rowWords > wordBudget {
                pages.append([])
                words = listStripBudget
            }
            pages[pages.count - 1].append(row)
            words += rowWords
        }
        return LensCard(screenfuls: pages.enumerated().map { position, page in
            position == 0 ? first + [.list(page)] : [.status("\(heading) · \(position + 1) of \(pages.count)"), .list(page)]
        })
    }

    static func species(_ candidate: Candidate, position: Int, of count: Int, isSaved: Bool, profile: SpeciesProfile?) -> LensCard {
        var strip = "\(count) species · \(position) of \(count)"
        if isSaved { strip += " · Saved" }
        var first: [LensElement] = [.status(strip)]
        if let photo = profile?.photo { first.append(.photo(photo)) }
        first.append(.title(candidate.species.commonName, detail: confidence(candidate)))

        // The fixed lines first, then the field marks take what is left of the budget.
        var fixed: [LensElement] = []
        if let profile {
            let sizeAndHabitat = [profile.size, profile.habitat].filter { !$0.isEmpty }.joined(separator: " · ")
            if !sizeAndHabitat.isEmpty { fixed.append(.meta(sizeAndHabitat.limited(toWords: metaLineBudget))) }
            fixed.append(.meta(profile.photo == nil ? "No photo in your pack" : profile.photoCredit.limited(toWords: metaLineBudget)))
        } else {
            fixed.append(.meta("Not in your pack"))
        }
        fixed.append(isSaved ? .saved("Saved ✓") : .button(saveButton))
        let budget = wordBudget - fixed.reduce(0) { $0 + $1.words } - first[0].words
        let text = profile.map(\.fieldMarks).flatMap { $0.isEmpty ? nil : $0 } ?? candidate.species.scientificName
        return LensCard(screenfuls: [first, [first[0], .body(text.limited(toWords: budget))] + fixed])
    }
}
