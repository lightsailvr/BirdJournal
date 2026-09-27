/// A species the session has heard convincingly, with what the engine knows about it so far.
public struct Candidate: Sendable, Equatable, Identifiable {
    public let species: Species
    /// The session score: the best single-window score so far, in [0, 1]. A maximum rather than a mean, so one
    /// clear call is not diluted by the quiet windows around it.
    public var score: Float
    /// Windows that scored at or above the window threshold.
    public var windowsAboveThreshold: Int
    /// Seconds into the session of the first and latest window above threshold, and of the window that admitted
    /// the species to the stack.
    public var firstHeardAt: Double
    public var lastHeardAt: Double
    public let admittedAt: Double

    public var id: Int { species.index }

    public init(species: Species, score: Float, windowsAboveThreshold: Int, firstHeardAt: Double, lastHeardAt: Double, admittedAt: Double) {
        self.species = species
        self.score = score
        self.windowsAboveThreshold = windowsAboveThreshold
        self.firstHeardAt = firstHeardAt
        self.lastHeardAt = lastHeardAt
        self.admittedAt = admittedAt
    }
}

/// The species admitted so far. `candidates` is in admission order and only ever grows at the end, so a card the
/// user is looking at keeps its position while scores change (spec user stories 12 and 26). `ranked` is the same
/// set ordered by score for "top N" questions.
public struct CandidateStack: Sendable, Equatable {
    public private(set) var candidates: [Candidate]

    public init(candidates: [Candidate] = []) {
        self.candidates = candidates
    }

    public var isEmpty: Bool { candidates.isEmpty }
    public var count: Int { candidates.count }

    /// Candidates by descending score; ties keep admission order.
    public var ranked: [Candidate] {
        candidates.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.score != rhs.element.score { return lhs.element.score > rhs.element.score }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    public func candidate(for species: Species) -> Candidate? {
        candidates.first { $0.species == species }
    }

    mutating func append(_ candidate: Candidate) {
        candidates.append(candidate)
    }

    mutating func update(_ candidate: Candidate) {
        guard let position = candidates.firstIndex(where: { $0.species == candidate.species }) else { return }
        candidates[position] = candidate
    }
}

/// Per-session aggregation of window scores into a `CandidateStack`.
///
/// A species is admitted after `admissionWindows` windows at or above `windowThreshold` (DECISIONS.md: two).
/// Species outside `allowedSpecies` are never counted, which is how the geomodel pre-filter takes effect.
public struct CandidateAggregator: Sendable {
    public let species: [Species]
    public let allowed: [Bool]
    public let windowThreshold: Float
    public let admissionWindows: Int

    public private(set) var stack = CandidateStack()
    private var scores: [Float]
    private var counts: [Int]
    private var firstHeard: [Double]
    private var admitted: [Double]

    /// - Parameters:
    ///   - species: the model's classes in output order.
    ///   - allowed: one flag per class; only allowed classes can enter the stack.
    public init(species: [Species], allowed: [Bool], windowThreshold: Float, admissionWindows: Int) {
        precondition(allowed.count == species.count, "allowed must have one flag per species")
        precondition(admissionWindows >= 1, "admissionWindows must be at least 1")
        self.species = species
        self.allowed = allowed
        self.windowThreshold = windowThreshold
        self.admissionWindows = admissionWindows
        scores = [Float](repeating: 0, count: species.count)
        counts = [Int](repeating: 0, count: species.count)
        firstHeard = [Double](repeating: 0, count: species.count)
        admitted = [Double](repeating: 0, count: species.count)
    }

    /// Folds one window's scores (one per class) into the session. Returns true if the stack changed.
    public mutating func observe(_ windowScores: [Float], at time: Double) -> Bool {
        precondition(windowScores.count == species.count, "one score per species")
        var changed = false
        for index in windowScores.indices where allowed[index] {
            let score = windowScores[index]
            guard score.isFinite, score >= windowThreshold else { continue }
            if counts[index] == 0 { firstHeard[index] = time }
            counts[index] += 1
            scores[index] = max(scores[index], score)
            guard counts[index] >= admissionWindows else { continue }
            if counts[index] == admissionWindows { admitted[index] = time }

            let candidate = Candidate(
                species: species[index],
                score: scores[index],
                windowsAboveThreshold: counts[index],
                firstHeardAt: firstHeard[index],
                lastHeardAt: time,
                admittedAt: admitted[index]
            )
            if counts[index] == admissionWindows {
                stack.append(candidate)
            } else {
                stack.update(candidate)
            }
            changed = true
        }
        return changed
    }
}
