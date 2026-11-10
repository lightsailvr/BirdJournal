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

    /// What is known about the bird in a photo besides its name (issue #189): what the run has heard, and what the geomodel
    /// expects where and when the photo was taken.
    struct Context: Equatable, Sendable {
        /// The scientific names of the birds heard this run, in the run's order: calling now first.
        var heard: [String] = []
        /// The geomodel's occurrence at the photo's place and week, by scientific name; nil without a place.
        var occurrence: [String: Float]? = nil

        /// No run and no place: the names alone.
        static let none = Context()

        /// Where a bird stands before its name is looked at: heard this run, in the run's order; else likely here, the
        /// likeliest first; else neither. The smaller, the sooner it is offered.
        struct Standing: Comparable, Sendable {
            fileprivate let tier: Int
            fileprivate let place: Float

            /// Heard this run or likely here.
            var isSuggested: Bool { tier < 2 }

            static func < (lhs: Standing, rhs: Standing) -> Bool {
                lhs.tier != rhs.tier ? lhs.tier < rhs.tier : lhs.place < rhs.place
            }
        }

        func standing(ofScientificName name: String) -> Standing {
            if let position = heard.firstIndex(of: name) { return Standing(tier: 0, place: Float(position)) }
            if let occurrence = occurrence?[name], occurrence >= NameableBirds.likelyFloor { return Standing(tier: 1, place: -occurrence) }
            return Standing(tier: 2, place: 0)
        }
    }

    /// What a search found.
    struct Results: Equatable, Sendable {
        /// "Heard this run", before anything is typed: the run's birds, in the run's order.
        var heard: [NameableBird] = []
        /// "Likely here now", before anything is typed: the field guides' birds the geomodel finds most likely at the
        /// photo's place and week, the likeliest first, without those heard.
        var likely: [NameableBird] = []
        /// "In your field guides": by common name.
        var fieldGuide: [NameableBird] = []
        /// "All birds": by common name, the first of them when there are many.
        var others: [NameableBird] = []
        /// How many more other birds matched than `others` lists.
        var moreOthers = 0

        /// Nothing to list.
        var isEmpty: Bool { heard.isEmpty && likely.isEmpty && fieldGuide.isEmpty && others.isEmpty }
    }

    /// How many other birds a search lists before it counts the rest: a broad search matches hundreds.
    static let otherLimit = 40
    /// The occurrence from which a bird is likely at a place and week: the floor under which identification doesn't admit a
    /// bird it hears there (`IdentificationConfiguration.occurrenceThreshold`, DECISIONS.md "Audio and identification").
    static let likelyFloor = IdentificationConfiguration().occurrenceThreshold
    /// How many likely birds are suggested before anything is typed.
    static let likelyLimit = 12

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

    /// What "Name this bird" lists for what was typed, given what the run and the place know (issue #189). The one ranking:
    /// the sheet draws it, and the lens's dictation (#194) orders its matches by the same `Context.Standing`.
    ///
    /// With nothing typed, suggestions: the birds heard this run, in the run's order, then the field guides' birds most
    /// likely at the place and week. Where no bird is likely (no place, or a place none of the field guides' birds are
    /// expected at) the field guides' birds are listed by name instead. Other birds are found by typing.
    ///
    /// With something typed, the birds whose names match, the field guides' first. The word-start rule has no better and
    /// worse matches, so within each list a bird heard this run comes first, then one likely here, then the rest by name.
    func search(_ query: String, in context: Context = .none, otherLimit: Int = NameableBirds.otherLimit, likelyLimit: Int = NameableBirds.likelyLimit) -> Results {
        let query = NameSearch.Query(query)
        guard !query.isEmpty else {
            var listed = Set<String>()
            let heard = context.heard.compactMap { byScientificName[$0] }.filter { listed.insert($0.scientificName).inserted }
            let likely = Self.ordered(fieldGuide.filter { !listed.contains($0.bird.scientificName) }, in: context) { $0.isSuggested }.prefix(likelyLimit)
            let byName = likely.isEmpty ? fieldGuide.map(\.bird).filter { !listed.contains($0.scientificName) } : []
            return Results(heard: heard, likely: Array(likely), fieldGuide: byName)
        }
        let matching = Self.ordered(others.filter { query.matches($0.words) }, in: context)
        return Results(
            fieldGuide: Self.ordered(fieldGuide.filter { query.matches($0.words) }, in: context),
            others: Array(matching.prefix(otherLimit)),
            moreOthers: max(matching.count - otherLimit, 0)
        )
    }

    /// `entries`, which are by name, by their standing in `context` and then by name; only those whose standing `keep` passes.
    private static func ordered(_ entries: [Entry], in context: Context, keep: (Context.Standing) -> Bool = { _ in true }) -> [NameableBird] {
        // Nothing heard and no place: every bird stands the same, and the order by name is the answer.
        guard context != .none else { return keep(context.standing(ofScientificName: "")) ? entries.map(\.bird) : [] }
        return entries.enumerated()
            .compactMap { position, entry -> (standing: Context.Standing, position: Int, bird: NameableBird)? in
                let standing = context.standing(ofScientificName: entry.bird.scientificName)
                return keep(standing) ? (standing, position, entry.bird) : nil
            }
            .sorted { $0.standing != $1.standing ? $0.standing < $1.standing : $0.position < $1.position }
            .map(\.bird)
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
