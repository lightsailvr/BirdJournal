import Testing
@testable import Identification

// Admission and ordering rules from DECISIONS.md ("a species enters the stack after two windows above
// threshold"; "stack never reorders, new species append at the end") and issue #5's acceptance criteria.
@Suite("CandidateAggregator")
struct CandidateAggregatorTests {
    private let finch = Species(index: 0, scientificName: "Haemorhous mexicanus", commonName: "House Finch", taxonomicClass: "Aves")
    private let jay = Species(index: 1, scientificName: "Cyanocitta cristata", commonName: "Blue Jay", taxonomicClass: "Aves")
    private let robin = Species(index: 2, scientificName: "Turdus migratorius", commonName: "American Robin", taxonomicClass: "Aves")

    private func aggregator(allowed: [Bool] = [true, true, true]) -> CandidateAggregator {
        CandidateAggregator(species: [finch, jay, robin], allowed: allowed, windowThreshold: 0.5, admissionWindows: 2)
    }

    @Test("a species enters the stack on its second window above threshold")
    func admittedAfterTwoWindows() {
        var aggregator = aggregator()

        #expect(aggregator.observe([0.6, 0, 0], at: 0) == false)
        #expect(aggregator.stack.isEmpty)
        #expect(aggregator.observe([0.9, 0, 0], at: 1.5) == true)

        #expect(aggregator.stack.candidates == [
            Candidate(species: finch, score: 0.9, windowsAboveThreshold: 2, firstHeardAt: 0, lastHeardAt: 1.5),
        ])
    }

    @Test("a window below threshold neither counts nor resets the count")
    func belowThresholdIgnored() {
        var aggregator = aggregator()
        _ = aggregator.observe([0.6, 0, 0], at: 0)
        _ = aggregator.observe([0.49, 0, 0], at: 1.5)
        #expect(aggregator.stack.isEmpty)
        _ = aggregator.observe([0.5, 0, 0], at: 3)
        #expect(aggregator.stack.count == 1)
    }

    @Test("a species outside the allowed set never appears, however loud")
    func filteredSpeciesNeverAppears() {
        var aggregator = aggregator(allowed: [true, false, true])
        for i in 0..<5 { _ = aggregator.observe([0, 1, 0], at: Double(i)) }
        #expect(aggregator.stack.isEmpty)
    }

    @Test("new species append at the end and existing ones keep their position as scores change")
    func stableOrdering() {
        var aggregator = aggregator()
        _ = aggregator.observe([0.6, 0.6, 0], at: 0)
        _ = aggregator.observe([0.6, 0.7, 0], at: 1.5)   // finch then jay admitted in index order
        _ = aggregator.observe([0.6, 0.6, 0.9], at: 3)
        _ = aggregator.observe([0.95, 0, 0.9], at: 4.5)  // robin admitted; finch's score jumps above jay's

        #expect(aggregator.stack.candidates.map(\.species) == [finch, jay, robin])
        #expect(aggregator.stack.candidates.map(\.score) == [0.95, 0.7, 0.9])
        #expect(aggregator.stack.candidates[0].windowsAboveThreshold == 4)
        #expect(aggregator.stack.candidates[0].lastHeardAt == 4.5)
        #expect(aggregator.stack.ranked.map(\.species) == [finch, robin, jay])
    }

    @Test("a NaN score is treated as silence")
    func nanIgnored() {
        var aggregator = aggregator()
        _ = aggregator.observe([.nan, 0, 0], at: 0)
        _ = aggregator.observe([.nan, 0, 0], at: 1.5)
        #expect(aggregator.stack.isEmpty)
    }

    @Test("ranking breaks score ties by admission order")
    func rankedTies() {
        let stack = CandidateStack(candidates: [
            Candidate(species: finch, score: 0.5, windowsAboveThreshold: 2, firstHeardAt: 0, lastHeardAt: 0),
            Candidate(species: jay, score: 0.5, windowsAboveThreshold: 2, firstHeardAt: 0, lastHeardAt: 0),
            Candidate(species: robin, score: 0.8, windowsAboveThreshold: 2, firstHeardAt: 0, lastHeardAt: 0),
        ])
        #expect(stack.ranked.map(\.species) == [robin, finch, jay])
    }
}
