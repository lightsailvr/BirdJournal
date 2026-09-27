import Foundation
import Testing
@testable import Identification

// The phone's live list (issue #6): ranked, but a species already shown above the fold never moves.
@Suite("LiveCandidateList")
struct LiveCandidateListTests {
    private let names = ["Finch", "Jay", "Robin", "Wren", "Towhee"]

    private func species(_ index: Int) -> Species {
        Species(index: index, scientificName: "S \(index)", commonName: names[index], taxonomicClass: "Aves")
    }

    /// A stack whose candidates were admitted in the given order with the given scores.
    private func stack(_ entries: [(Int, Float)]) -> CandidateStack {
        CandidateStack(candidates: entries.map { index, score in
            Candidate(species: species(index), score: score, windowsAboveThreshold: 2, firstHeardAt: 0, lastHeardAt: 0, admittedAt: 0)
        })
    }

    @Test("a new species appears below the ones already shown, even when it outscores them")
    func newSpeciesAppendBelowTheFold() {
        var list = LiveCandidateList(foldSize: 4)
        list.update(with: stack([(0, 0.3)]))
        #expect(list.rows.map(\.species.commonName) == ["Finch"])

        list.update(with: stack([(0, 0.3), (1, 0.9)]))
        #expect(list.rows.map(\.species.commonName) == ["Finch", "Jay"])
    }

    @Test("below the fold, rows are ranked by score and re-rank as scores change; the fold never moves")
    func tailIsRankedFoldIsFrozen() {
        var list = LiveCandidateList(foldSize: 2)
        list.update(with: stack([(0, 0.3), (1, 0.5), (2, 0.4), (3, 0.8)]))  // all new at once: ranked
        #expect(list.rows.map(\.species.commonName) == ["Wren", "Jay", "Robin", "Finch"])

        list.update(with: stack([(0, 0.1), (1, 0.5), (2, 0.95), (3, 0.8)]))  // Robin now tops everything
        #expect(list.rows.map(\.species.commonName) == ["Wren", "Jay", "Robin", "Finch"])
        #expect(list.rows.map(\.score) == [0.8, 0.5, 0.95, 0.1])
    }

    @Test("once the fold fills, the species that filled it are frozen and later arrivals rank below")
    func foldFreezesWhenFilled() {
        var list = LiveCandidateList(foldSize: 2)
        list.update(with: stack([(0, 0.3)]))
        list.update(with: stack([(0, 0.3), (1, 0.2), (2, 0.9)]))  // two admitted at once: ranked into the free slot
        #expect(list.rows.map(\.species.commonName) == ["Finch", "Robin", "Jay"])

        list.update(with: stack([(0, 0.3), (1, 0.99), (2, 0.9), (4, 0.95)]))
        #expect(list.rows.map(\.species.commonName) == ["Finch", "Robin", "Jay", "Towhee"])
    }

    @Test("ties rank in admission order, and the same stack again changes nothing")
    func tiesAndIdempotence() {
        var list = LiveCandidateList(foldSize: 1)
        let stack = stack([(0, 0.5), (1, 0.7), (2, 0.7), (3, 0.7)])
        list.update(with: stack)
        let once = list
        list.update(with: stack)
        #expect(list == once)
        #expect(list.rows.map(\.species.commonName) == ["Jay", "Robin", "Wren", "Finch"])
    }
}
