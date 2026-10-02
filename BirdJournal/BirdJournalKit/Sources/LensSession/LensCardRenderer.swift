import Identification

/// Maps a page and the stack to its card (spec "Card renderer", issue #24): the species list (count, one row per
/// species on the page holding the selected row, which is highlighted), the photo page (photo, name and match rate,
/// status strip and a hint) and the details page (name, field marks, size and habitat, credit and "Add to my list"
/// or the saved mark) and the problem page (what went wrong, what it means for the run, the way back). Every page
/// fits the canvas. No page exceeds `wordBudget` words (spec user story 24) but the details page, whose field marks
/// are set in the small style and get `detailsWordBudget` less the fixed lines (issue #32); pack text is cut to
/// fit, field marks first.
///
/// The list's rows are in `order`, the calling section first, each calling row marked (issue #42), and paged by
/// row position so a pinned bird pushed down the list pages the view with it. A species card's strip says
/// "calling now" for its own bird, or names the bird calling now; the details page carries a strip only then.
public enum LensCardRenderer {
    public static let wordBudget = 40
    /// The details page's budget: forty words of field marks in the small style (the pack builder's
    /// `FIELD_MARKS_WORDS`, so pack text is never cut here) plus the name, match rate, size and habitat, credit
    /// and button. Checked on the mock lens: the page fits the 600 px canvas.
    public static let detailsWordBudget = 64
    /// The most words a card spends on its size-and-habitat line and on its credit line.
    static let metaLineBudget = 8
    /// Rows on one page of the list. The app re-sends the list on every selection move and a send starts at the top,
    /// so the rows are paged rather than scrolled, and few enough to fit the canvas with the heading.
    public static let listRowsPerPage = 5
    static let saveButton = LensCardButton(label: "Add to my list", action: .save)

    public static func render(_ page: LensPage, stack: CandidateStack, order: SpeciesListOrder, selection: Int, saved: Set<Int>, profile: (Species) -> SpeciesProfile?) -> LensCard {
        switch page {
        case .list:
            return list(stack, order: order, selection: selection, saved: saved, profile: profile)
        case .species(let index):
            let candidate = stack.candidates[index]
            return species(candidate, position: index + 1, of: stack.count, isSaved: saved.contains(index), calling: callingText(for: index, stack: stack, order: order), profile: profile(candidate.species))
        case .details(let index):
            let candidate = stack.candidates[index]
            return details(candidate, isSaved: saved.contains(index), calling: callingText(for: index, stack: stack, order: order), profile: profile(candidate.species))
        case .problem(let problem):
            return self.problem(problem)
        }
    }

    /// What a species card says about calling: "calling now" for its own bird, "Now: <name>" when another bird
    /// is (the newest caller), nil when none is.
    static func callingText(for index: Int, stack: CandidateStack, order: SpeciesListOrder) -> String? {
        if order.isCalling(index: index) { return "calling now" }
        guard let newest = order.calling.first else { return nil }
        return "Now: \(stack.candidates[newest].species.commonName)"
    }

    /// The session score as a percentage, e.g. "82% match".
    public static func confidence(_ candidate: Candidate) -> String {
        "\(percent(candidate)) match"
    }

    static func percent(_ candidate: Candidate) -> String {
        "\(Int((candidate.score * 100).rounded()))%"
    }

    static func list(_ stack: CandidateStack, order: SpeciesListOrder, selection: Int, saved: Set<Int>, profile: (Species) -> SpeciesProfile?) -> LensCard {
        let heading = switch stack.count {
        case 0: "No species yet"
        case 1: "1 species heard"
        default: "\(stack.count) species heard"
        }
        guard !stack.isEmpty else {
            return LensCard(screenfuls: [[.heading(heading), .meta("Cards appear as birds call.")]])
        }
        let indices = order.indices.count == stack.count ? order.indices : Array(stack.candidates.indices)
        let pages = (indices.count + listRowsPerPage - 1) / listRowsPerPage
        let page = (indices.firstIndex(of: selection) ?? 0) / listRowsPerPage
        let start = page * listRowsPerPage
        let rows = indices[start..<min(start + listRowsPerPage, indices.count)].map { index in
            let candidate = stack.candidates[index]
            return LensListRow(
                index: index,
                commonName: candidate.species.commonName,
                confidence: percent(candidate),
                hasPhoto: profile(candidate.species)?.photo != nil,
                isSaved: saved.contains(index),
                isSelected: index == selection,
                isCalling: order.isCalling(index: index)
            )
        }
        var hint = "Swipe down to choose, tap to open."
        if pages > 1 { hint += " Page \(page + 1) of \(pages)." }
        return LensCard(screenfuls: [[.heading(heading), .meta(hint), .list(rows)]])
    }

    static func species(_ candidate: Candidate, position: Int, of count: Int, isSaved: Bool, calling: String?, profile: SpeciesProfile?) -> LensCard {
        // The photo first, so nothing above it can push it below the fold on the glasses.
        var elements: [LensElement] = []
        if let photo = profile?.photo { elements.append(.photo(photo)) }
        elements.append(.title(candidate.species.commonName, detail: confidence(candidate)))
        let strip = ["\(count) species · \(position) of \(count)", isSaved ? "Added" : nil, calling].compactMap { $0 }
        elements.append(.status(strip.joined(separator: " · ")))
        elements.append(.meta("Swipe down for more information · swipe right: all species"))
        return LensCard(screenfuls: [elements])
    }

    static func problem(_ problem: LensProblem) -> LensCard {
        let (heading, body) = switch problem {
        case .noLocation:
            ("No location", "Species are not filtered by your region. Allow location for BirdJournal in Settings on the phone.")
        case .connectionLost:
            ("Connection lost", "The glasses were out of range. BirdJournal kept listening and is back on the lens.")
        }
        return LensCard(screenfuls: [[.heading(heading), .body(body), .meta("Swipe right to continue")]])
    }

    static func details(_ candidate: Candidate, isSaved: Bool, calling: String?, profile: SpeciesProfile?) -> LensCard {
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
        var top = [LensElement.title(candidate.species.commonName, detail: confidence(candidate))]
        if let calling { top.append(.status(calling.prefix(1).uppercased() + calling.dropFirst())) }
        let budget = detailsWordBudget - fixed.wordCount - top.wordCount
        let text = profile.map(\.fieldMarks).flatMap { $0.isEmpty ? nil : $0 } ?? candidate.species.scientificName
        return LensCard(screenfuls: [top + [.passage(text.limited(toWords: budget))] + fixed])
    }
}
