import Identification

/// Maps a page and the stack to its card (spec "Card renderer", issue #24): the species list (count, one row per
/// species on the page holding the selected row, which is highlighted), the photo page (photo, name and match rate,
/// status strip and a hint) and the details page (name, field marks, size and habitat, credit and "Add to my list"
/// or the saved mark). Every page fits the canvas. No page exceeds `wordBudget` words (spec user story 24): pack
/// text is cut to fit, field marks first.
public enum LensCardRenderer {
    public static let wordBudget = 40
    /// The most words a card spends on its size-and-habitat line and on its credit line.
    static let metaLineBudget = 8
    /// Rows on one page of the list. The app re-sends the list on every selection move and a send starts at the top,
    /// so the rows are paged rather than scrolled, and few enough to fit the canvas with the heading.
    public static let listRowsPerPage = 5
    static let saveButton = LensCardButton(label: "Add to my list", action: .save)

    public static func render(_ page: LensPage, stack: CandidateStack, selection: Int, saved: Set<Int>, profile: (Species) -> SpeciesProfile?) -> LensCard {
        switch page {
        case .list:
            return list(stack, selection: selection, saved: saved, profile: profile)
        case .species(let index):
            let candidate = stack.candidates[index]
            return species(candidate, position: index + 1, of: stack.count, isSaved: saved.contains(index), profile: profile(candidate.species))
        case .details(let index):
            let candidate = stack.candidates[index]
            return details(candidate, isSaved: saved.contains(index), profile: profile(candidate.species))
        }
    }

    /// The session score as a percentage, e.g. "82% match".
    public static func confidence(_ candidate: Candidate) -> String {
        "\(percent(candidate)) match"
    }

    static func percent(_ candidate: Candidate) -> String {
        "\(Int((candidate.score * 100).rounded()))%"
    }

    static func list(_ stack: CandidateStack, selection: Int, saved: Set<Int>, profile: (Species) -> SpeciesProfile?) -> LensCard {
        let heading = switch stack.count {
        case 0: "No species yet"
        case 1: "1 species heard"
        default: "\(stack.count) species heard"
        }
        guard !stack.isEmpty else {
            return LensCard(screenfuls: [[.heading(heading), .meta("Cards appear as birds call.")]])
        }
        let pages = (stack.count + listRowsPerPage - 1) / listRowsPerPage
        let page = min(max(selection, 0), stack.count - 1) / listRowsPerPage
        let start = page * listRowsPerPage
        let rows = stack.candidates[start..<min(start + listRowsPerPage, stack.count)].enumerated().map { offset, candidate in
            let index = start + offset
            return LensListRow(
                index: index,
                commonName: candidate.species.commonName,
                confidence: percent(candidate),
                hasPhoto: profile(candidate.species)?.photo != nil,
                isSaved: saved.contains(index),
                isSelected: index == selection
            )
        }
        var hint = "Swipe down to choose, tap to open."
        if pages > 1 { hint += " Page \(page + 1) of \(pages)." }
        return LensCard(screenfuls: [[.heading(heading), .meta(hint), .list(rows)]])
    }

    static func species(_ candidate: Candidate, position: Int, of count: Int, isSaved: Bool, profile: SpeciesProfile?) -> LensCard {
        // The photo first, so nothing above it can push it below the fold on the glasses.
        var elements: [LensElement] = []
        if let photo = profile?.photo { elements.append(.photo(photo)) }
        elements.append(.title(candidate.species.commonName, detail: confidence(candidate)))
        elements.append(.status("\(count) species · \(position) of \(count)" + (isSaved ? " · Added" : "")))
        elements.append(.meta("Swipe down for more information · swipe right: all species"))
        return LensCard(screenfuls: [elements])
    }

    static func details(_ candidate: Candidate, isSaved: Bool, profile: SpeciesProfile?) -> LensCard {
        // The fixed lines first, then the field marks take what is left of the budget.
        var fixed: [LensElement] = []
        if let profile {
            let sizeAndHabitat = [profile.size, profile.habitat].filter { !$0.isEmpty }.joined(separator: " · ")
            if !sizeAndHabitat.isEmpty { fixed.append(.meta(sizeAndHabitat.limited(toWords: metaLineBudget))) }
            fixed.append(.meta(profile.photo == nil ? "No photo in your pack" : profile.photoCredit.limited(toWords: metaLineBudget)))
        } else {
            fixed.append(.meta("Not in your pack"))
        }
        fixed.append(isSaved ? .saved("Added to my list ✓") : .button(saveButton))
        let title = LensElement.title(candidate.species.commonName, detail: confidence(candidate))
        let budget = wordBudget - fixed.wordCount - title.words
        let text = profile.map(\.fieldMarks).flatMap { $0.isEmpty ? nil : $0 } ?? candidate.species.scientificName
        return LensCard(screenfuls: [[title, .body(text.limited(toWords: budget))] + fixed])
    }
}
