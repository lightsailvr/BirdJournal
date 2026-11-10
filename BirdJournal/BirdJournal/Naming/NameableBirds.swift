import Album
import Foundation
import Identification
import Pack

/// A bird a seen sighting can be named (issue #186): one a field-guide download on the phone describes, or any other bird
/// the BirdNET label list knows by name.
nonisolated struct NameableBird: Identifiable, Hashable, Sendable {
    /// The label the sighting is written under: BirdNET's own for the bird where it has one, so a seen sighting and a heard
    /// one of the same bird share a patch.
    let speciesID: String
    let scientificName: String
    /// The field guide's name for it, else the label's.
    let commonName: String
    /// A field-guide download on the phone describes it.
    let isInFieldGuide: Bool

    var id: String { scientificName }
}

/// The birds a photo can be named as, and the search over them (issue #186): the field guides' birds first, then every other
/// bird BirdNET knows, each by its common or scientific name under the search rule the Collection and the Atlas use
/// (`NameSearch`). A pure value, built once from the packs on the phone and the label list; the names are split once, since
/// there are some ten thousand and the search runs on every keystroke.
///
/// The seam for what orders the results: #189's suggestions and ranking, and the lens's dictation (#194), replace `search`'s
/// alphabetical order here, not in the sheet.
nonisolated struct NameableBirds: Sendable {
    /// A bird a field-guide download describes, as its pack names it.
    struct FieldGuideBird: Hashable, Sendable {
        let scientificName: String
        let commonName: String
    }

    /// What a search found.
    struct Results: Equatable, Sendable {
        /// "In your field guides": by common name.
        var fieldGuide: [NameableBird] = []
        /// "All birds": by common name, the first of them when there are many.
        var others: [NameableBird] = []
        /// How many more other birds matched than `others` lists.
        var moreOthers = 0

        /// Nothing matched.
        var isEmpty: Bool { fieldGuide.isEmpty && others.isEmpty }
    }

    /// How many other birds a search lists before it counts the rest: a broad search matches hundreds.
    static let otherLimit = 40

    private struct Entry: Sendable {
        let bird: NameableBird
        let words: NameSearch.Words
    }

    private let fieldGuide: [Entry]
    private let others: [Entry]
    private let byScientificName: [String: NameableBird]

    /// - Parameters:
    ///   - fieldGuide: the species of the packs on the phone, bundled first; a bird in two packs counts once.
    ///   - labels: the BirdNET label list. Only its birds can be named: it also knows frogs, insects and mammals.
    init(fieldGuide: [FieldGuideBird], labels: [Species]) {
        let birds = labels.filter { $0.taxonomicClass == Species.birds }
        let labelled = Dictionary(birds.map { ($0.scientificName, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var described: [Entry] = []
        for entry in fieldGuide where seen.insert(entry.scientificName).inserted {
            let label = labelled[entry.scientificName]
            let bird = NameableBird(
                speciesID: label?.birdnetLabel ?? "\(entry.scientificName)_\(entry.commonName)",
                scientificName: entry.scientificName, commonName: entry.commonName, isInFieldGuide: true
            )
            // BirdNET's own name for it finds it too, where the pack spells it differently.
            described.append(Entry(bird: bird, words: NameSearch.Words([entry.commonName, entry.scientificName, label?.commonName ?? ""])))
        }
        let rest = birds.filter { !seen.contains($0.scientificName) }.map { species in
            Entry(
                bird: NameableBird(speciesID: species.birdnetLabel, scientificName: species.scientificName, commonName: species.commonName, isInFieldGuide: false),
                words: NameSearch.Words([species.commonName, species.scientificName])
            )
        }
        self.fieldGuide = described.sorted(by: Self.byName)
        others = rest.sorted(by: Self.byName)
        byScientificName = Dictionary((described + rest).map { ($0.bird.scientificName, $0.bird) }, uniquingKeysWith: { first, _ in first })
    }

    private static func byName(_ lhs: Entry, _ rhs: Entry) -> Bool {
        lhs.bird.commonName.localizedCaseInsensitiveCompare(rhs.bird.commonName) == .orderedAscending
    }

    /// The birds whose names `query` matches. With nothing typed, the field guides' birds and no others: the rest are found
    /// by typing.
    func search(_ query: String, otherLimit: Int = NameableBirds.otherLimit) -> Results {
        let query = NameSearch.Query(query)
        guard !query.isEmpty else { return Results(fieldGuide: fieldGuide.map(\.bird)) }
        let matching = others.filter { query.matches($0.words) }
        return Results(
            fieldGuide: fieldGuide.filter { query.matches($0.words) }.map(\.bird),
            others: matching.prefix(otherLimit).map(\.bird),
            moreOthers: max(matching.count - otherLimit, 0)
        )
    }

    /// The bird with this scientific name, if it can be named.
    func bird(scientificName: String) -> NameableBird? {
        byScientificName[scientificName]
    }
}

nonisolated extension NameableBirds {
    /// The names over the packs on the phone and the bundled label list. Reading and splitting ten thousand names takes a
    /// moment, so this is called off the main actor.
    static func load(fieldGuide: [FieldGuideBird]) throws -> NameableBirds {
        NameableBirds(fieldGuide: fieldGuide, labels: try ONNXBirdModel.bundledLabels())
    }
}

extension PackLibrary {
    /// Every species the packs on the phone describe, bundled first, for `NameableBirds`.
    var fieldGuideBirds: [NameableBirds.FieldGuideBird] {
        packs.flatMap { pack in pack.species.map { NameableBirds.FieldGuideBird(scientificName: $0.scientificName, commonName: $0.commonName) } }
    }
}
