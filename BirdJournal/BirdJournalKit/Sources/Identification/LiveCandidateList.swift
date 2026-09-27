/// The phone's live candidate list (issue #6): what the screen shows, in the order it shows it.
///
/// Rows above the fold (the first `foldSize`) are frozen once shown: a species that reached a visible position keeps
/// it for the rest of the session, whatever its score does. New species enter below, where rows are ranked by
/// score, so the list is live without shuffling what the birder is already reading. Scores update in place.
public struct LiveCandidateList: Sendable, Equatable {
    /// Rows the screen fits without scrolling on a phone, above the controls.
    public static let defaultFoldSize = 6

    public let foldSize: Int
    public private(set) var rows: [Candidate] = []

    public init(foldSize: Int = LiveCandidateList.defaultFoldSize) {
        precondition(foldSize >= 1, "the fold must hold at least one row")
        self.foldSize = foldSize
    }

    public var isEmpty: Bool { rows.isEmpty }

    /// Folds a new stack in. Frozen rows refresh their candidate but keep their place; every other row and every
    /// newly admitted species is ranked by score below them, ties in admission order.
    public mutating func update(with stack: CandidateStack) {
        let latest = Dictionary(uniqueKeysWithValues: stack.candidates.enumerated().map { ($0.element.species, (order: $0.offset, candidate: $0.element)) })
        var frozen: [Candidate] = []
        var ranked: [(order: Int, candidate: Candidate)] = []
        var seen = Set<Species>()
        for (position, row) in rows.enumerated() {
            guard let entry = latest[row.species] else { continue }
            seen.insert(row.species)
            if position < foldSize {
                frozen.append(entry.candidate)
            } else {
                ranked.append(entry)
            }
        }
        for (order, candidate) in stack.candidates.enumerated() where !seen.contains(candidate.species) {
            ranked.append((order, candidate))
        }
        ranked.sort { lhs, rhs in
            if lhs.candidate.score != rhs.candidate.score { return lhs.candidate.score > rhs.candidate.score }
            return lhs.order < rhs.order
        }
        rows = frozen + ranked.map(\.candidate)
    }
}
