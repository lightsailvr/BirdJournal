import Testing
@testable import Identification

// Issue #42: the list page's presentation order over a stack that never reorders. A species is calling now when its
// last window above threshold is within the last six seconds of session time; calling birds come first, newest
// caller, then the one calling longest, then the rest newest first; everything else follows most recently heard
// first. "Calling since" is when the bird entered the section, so a chorus does not shuffle.
@Suite("SpeciesListOrder")
struct SpeciesListOrderTests {
    static let finch = Species(index: 0, scientificName: "Haemorhous mexicanus", commonName: "House Finch", taxonomicClass: "Aves")
    static let jay = Species(index: 1, scientificName: "Cyanocitta cristata", commonName: "Blue Jay", taxonomicClass: "Aves")
    static let robin = Species(index: 2, scientificName: "Turdus migratorius", commonName: "American Robin", taxonomicClass: "Aves")
    static let wren = Species(index: 3, scientificName: "Thryomanes bewickii", commonName: "Bewick's Wren", taxonomicClass: "Aves")

    static func candidate(_ species: Species, lastHeardAt: Double, firstHeardAt: Double = 0) -> Candidate {
        Candidate(species: species, score: 0.8, windowsAboveThreshold: 2, firstHeardAt: firstHeardAt, lastHeardAt: lastHeardAt, admittedAt: firstHeardAt + 1.5)
    }

    @Test("a species is calling now for six seconds after its last window above threshold")
    func callingWindow() {
        let candidate = Self.candidate(Self.finch, lastHeardAt: 10)
        #expect(SpeciesListOrder.isCalling(candidate, at: 10))
        #expect(SpeciesListOrder.isCalling(candidate, at: 15.9))
        #expect(!SpeciesListOrder.isCalling(candidate, at: 16))
        #expect(!SpeciesListOrder.isCalling(candidate, at: 60))
    }

    // MARK: - The two sections

    @Test("calling birds come first, then the rest most recently heard first; a bird heard once sinks")
    func sections() {
        // Admission order: finch (heard once, early), jay, robin (calling), wren (heard again lately).
        let stack = CandidateStack(candidates: [
            Self.candidate(Self.finch, lastHeardAt: 3),
            Self.candidate(Self.jay, lastHeardAt: 40),
            Self.candidate(Self.robin, lastHeardAt: 99),
            Self.candidate(Self.wren, lastHeardAt: 80),
        ])
        var order = SpeciesListOrder()
        order.update(with: stack, at: 100)
        #expect(order.indices == [2, 3, 1, 0])
        #expect(order.callingCount == 1)
        #expect(order.isCalling(index: 2))
        #expect(!order.isCalling(index: 3))
    }

    @Test("ties on the last window keep admission order")
    func ties() {
        var order = SpeciesListOrder()
        order.update(with: CandidateStack(candidates: [
            Self.candidate(Self.finch, lastHeardAt: 3), Self.candidate(Self.jay, lastHeardAt: 3), Self.candidate(Self.robin, lastHeardAt: 3),
        ]), at: 100)
        #expect(order.indices == [0, 1, 2])
        #expect(order.callingCount == 0)
    }

    @Test("an empty stack has an empty order and no lapse")
    func empty() {
        var order = SpeciesListOrder()
        order.update(with: CandidateStack(), at: 5)
        #expect(order.indices.isEmpty)
        #expect(order.nextLapse == nil)
    }

    // MARK: - Newest, then longest

    @Test("with two calling birds the newest is first and the one calling longest second; a third pushes the previous newest to row three")
    func newestThenLongest() {
        var order = SpeciesListOrder()
        var candidates = [
            Self.candidate(Self.finch, lastHeardAt: 10),
            Self.candidate(Self.jay, lastHeardAt: 11.5),
        ]
        order.update(with: CandidateStack(candidates: candidates), at: 12)
        #expect(order.indices == [1, 0], "jay newest, finch longest")

        // Both keep calling; the robin starts: robin, finch (longest), jay (the previous newest).
        candidates[0].lastHeardAt = 13
        candidates[1].lastHeardAt = 13
        candidates.append(Self.candidate(Self.robin, lastHeardAt: 13, firstHeardAt: 11.5))
        order.update(with: CandidateStack(candidates: candidates), at: 13.5)
        #expect(order.indices == [2, 0, 1])
        #expect(order.callingCount == 3)
    }

    @Test("two birds alternating in a chorus keep their rows: calling since is when the bird entered the section")
    func chorusDoesNotSwap() {
        var order = SpeciesListOrder()
        var candidates = [Self.candidate(Self.finch, lastHeardAt: 10), Self.candidate(Self.jay, lastHeardAt: 11.5)]
        order.update(with: CandidateStack(candidates: candidates), at: 12)
        #expect(order.indices == [1, 0])
        for (step, window) in stride(from: 13.0, through: 30, by: 1.5).enumerated() {
            // The finch and the jay take turns, one window each; both stay inside the six-second window.
            if step.isMultiple(of: 2) { candidates[0].lastHeardAt = window } else { candidates[1].lastHeardAt = window }
            order.update(with: CandidateStack(candidates: candidates), at: window + 0.5)
            #expect(order.indices == [1, 0], "shuffled at \(window)")
        }
    }

    // MARK: - Going quiet

    @Test("a bird that goes quiet drops in at the top of the earlier section, and calls again from the top")
    func quietBirdDropsToTopOfEarlier() {
        var order = SpeciesListOrder()
        var candidates = [
            Self.candidate(Self.finch, lastHeardAt: 3),
            Self.candidate(Self.jay, lastHeardAt: 20),
            Self.candidate(Self.robin, lastHeardAt: 26),
        ]
        order.update(with: CandidateStack(candidates: candidates), at: 27)
        #expect(order.indices == [2, 1, 0])
        #expect(order.callingCount == 1)
        #expect(order.nextLapse == 32)

        // The robin lapses with nothing else changing.
        order.update(with: CandidateStack(candidates: candidates), at: 32)
        #expect(order.indices == [2, 1, 0])
        #expect(order.callingCount == 0)
        #expect(order.nextLapse == nil)

        // The jay calls again: it is the newest caller; the robin heads the earlier section.
        candidates[1].lastHeardAt = 40
        order.update(with: CandidateStack(candidates: candidates), at: 41)
        #expect(order.indices == [1, 2, 0])
        #expect(order.callingCount == 1)
        #expect(order.nextLapse == 46)
    }

    @Test("the next lapse is the earliest calling bird's")
    func nextLapse() {
        var order = SpeciesListOrder()
        order.update(with: CandidateStack(candidates: [
            Self.candidate(Self.finch, lastHeardAt: 10), Self.candidate(Self.jay, lastHeardAt: 8),
        ]), at: 12)
        #expect(order.callingCount == 2)
        #expect(order.nextLapse == 14)
    }

    @Test("a stack from a new session starts the sections over")
    func newSession() {
        var order = SpeciesListOrder()
        order.update(with: CandidateStack(candidates: [Self.candidate(Self.finch, lastHeardAt: 100), Self.candidate(Self.jay, lastHeardAt: 101)]), at: 102)
        #expect(order.indices == [1, 0])
        // Same species, a session that started over: the finch is the only caller so far.
        order.update(with: CandidateStack(candidates: [Self.candidate(Self.finch, lastHeardAt: 2)]), at: 3)
        #expect(order.indices == [0])
        #expect(order.callingCount == 1)
        order.update(with: CandidateStack(candidates: [Self.candidate(Self.finch, lastHeardAt: 2), Self.candidate(Self.jay, lastHeardAt: 4)]), at: 4.5)
        #expect(order.indices == [1, 0], "the jay is the newest caller of the new session")
    }
}
