/// The list page's presentation order over a `CandidateStack` (issue #42). The stack itself never reorders (its
/// indices are what the card pages, the saved marks and the selection use); this is the order the list shows those
/// indices in, recomputed on every update with enough memory that a chorus does not shuffle the rows.
///
/// Two sections. **Calling now**: the species whose last window above threshold is within `callingWindow` of the
/// session time, the newest caller first, the bird calling the longest second, then the others newest first.
/// "Calling since" is when the species entered the section, not its last window, so two birds alternating in a
/// chorus keep their rows. **Heard earlier**: everything else, most recently heard first, so a bird that goes
/// quiet drops in at the top of this section and birds heard once sink to the bottom on their own.
public struct SpeciesListOrder: Sendable, Equatable {
    /// How long after its last window above threshold a species counts as calling now: one 3 s window plus two
    /// 1.5 s hops, so a single missed window does not drop the marker.
    public static let callingWindow: Double = 6

    /// Every stack index, in the order the list shows them: the calling section first.
    public private(set) var indices: [Int] = []
    /// How many of `indices`, from the front, are calling now.
    public private(set) var callingCount = 0
    /// The session time at which the earliest calling marker lapses with no further windows, nil when none is
    /// calling. Nothing in the stack changes at a lapse, so whoever shows the list must come back at this time.
    public private(set) var nextLapse: Double?
    /// When each calling species entered the section (the window that put it there).
    private var callingSince: [Species: Double] = [:]

    public init() {}

    /// Whether `candidate` is calling now at session time `time`.
    public static func isCalling(_ candidate: Candidate, at time: Double) -> Bool {
        time - candidate.lastHeardAt < callingWindow
    }

    /// The calling section's stack indices, in list order.
    public var calling: ArraySlice<Int> { indices.prefix(callingCount) }

    public func isCalling(index: Int) -> Bool {
        calling.contains(index)
    }

    /// The row position of a stack index, nil when the index is not in the order.
    public func position(of index: Int) -> Int? {
        indices.firstIndex(of: index)
    }

    /// Recomputes the order for `stack` at session time `time`. A stack from a new session (a species whose last
    /// window is earlier than when it entered the calling section) starts the sections over.
    public mutating func update(with stack: CandidateStack, at time: Double) {
        var since: [Species: Double] = [:]
        var calling: [(index: Int, since: Double)] = []
        var earlier: [(index: Int, lastHeardAt: Double)] = []
        var lapse: Double?
        for (index, candidate) in stack.candidates.enumerated() {
            if Self.isCalling(candidate, at: time) {
                let entered = callingSince[candidate.species].flatMap { $0 <= candidate.lastHeardAt ? $0 : nil } ?? candidate.lastHeardAt
                since[candidate.species] = entered
                calling.append((index, entered))
                lapse = min(lapse ?? .infinity, candidate.lastHeardAt + Self.callingWindow)
            } else {
                earlier.append((index, candidate.lastHeardAt))
            }
        }
        callingSince = since
        nextLapse = lapse

        // Newest first (a later admission is the newer of two that entered together), then the longest second.
        var callingOrder = calling.sorted { lhs, rhs in
            if lhs.since != rhs.since { return lhs.since > rhs.since }
            return lhs.index > rhs.index
        }
        if callingOrder.count >= 2, let longest = callingOrder.indices.min(by: { lhs, rhs in
            if callingOrder[lhs].since != callingOrder[rhs].since { return callingOrder[lhs].since < callingOrder[rhs].since }
            return callingOrder[lhs].index < callingOrder[rhs].index
        }) {
            let row = callingOrder.remove(at: longest)
            callingOrder.insert(row, at: 1)
        }
        let earlierOrder = earlier.sorted { lhs, rhs in
            if lhs.lastHeardAt != rhs.lastHeardAt { return lhs.lastHeardAt > rhs.lastHeardAt }
            return lhs.index < rhs.index
        }
        indices = callingOrder.map(\.index) + earlierOrder.map(\.index)
        callingCount = callingOrder.count
    }
}
