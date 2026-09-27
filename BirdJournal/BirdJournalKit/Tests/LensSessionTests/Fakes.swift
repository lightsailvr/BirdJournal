import Identification
@testable import LensSession

/// A hard-coded stack for the state machine and renderer tests: three species in admission order.
enum Fakes {
    static let phoebe = Species(index: 0, scientificName: "Sayornis nigricans", commonName: "Black Phoebe", taxonomicClass: "Aves")
    static let finch = Species(index: 1, scientificName: "Haemorhous mexicanus", commonName: "House Finch", taxonomicClass: "Aves")
    static let towhee = Species(index: 2, scientificName: "Melozone crissalis", commonName: "California Towhee", taxonomicClass: "Aves")
    static let all = [phoebe, finch, towhee]

    static func candidate(_ species: Species, score: Float = 0.8) -> Candidate {
        Candidate(species: species, score: score, windowsAboveThreshold: 2, firstHeardAt: 0, lastHeardAt: 3, admittedAt: 3)
    }

    /// The first `count` fake species as a stack.
    static func stack(_ count: Int) -> CandidateStack {
        CandidateStack(candidates: all.prefix(count).map { candidate($0) })
    }

    static let phoebeProfile = SpeciesProfile(
        photo: LensImage(id: "sayornis-nigricans-1"),
        fieldMarks: "Sooty black with a clean white belly; wags its tail while perched low near water.",
        size: "Sparrow-sized",
        habitat: "Streams, ponds, lawns",
        photoCredit: "Photo: J. Birder, CC BY"
    )
}
