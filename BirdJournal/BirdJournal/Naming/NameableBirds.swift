import Album
import Foundation
import Identification
import OSLog
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
/// What orders the results is here and not in the sheet (issue #189): `search(_:in:)` takes what the run has heard and what
/// the geomodel expects at the place, suggests from them before anything is typed, and ranks a typed search by them. The
/// lens's dictation (#194) ranks its matches by the same `Context.Standing`.
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
            /// 0 heard, 1 likely, 2 neither.
            fileprivate let tier: Int
            /// Within the tier: the position in the run's order, or the occurrence, negated.
            fileprivate let order: Float

            /// Heard this run or likely here.
            var isSuggested: Bool { tier < 2 }

            static func < (lhs: Standing, rhs: Standing) -> Bool {
                lhs.tier != rhs.tier ? lhs.tier < rhs.tier : lhs.order < rhs.order
            }
        }

        /// The standing of the bird with this scientific name. Birds that stand the same are told apart by whoever asks:
        /// the search, by name.
        func standing(ofScientificName name: String) -> Standing {
            if let position = heard.firstIndex(of: name) { return Standing(tier: 0, order: Float(position)) }
            if let occurrence = occurrence?[name], occurrence >= NameableBirds.likelyFloor { return Standing(tier: 1, order: -occurrence) }
            return Standing(tier: 2, order: 0)
        }

        /// Nothing heard and no place: every bird stands the same.
        var isEmpty: Bool { heard.isEmpty && occurrence == nil }
    }

    /// What a search found.
    struct Results: Equatable, Sendable {
        /// "Heard this run", before anything is typed: the run's birds, in the run's order.
        var heard: [NameableBird] = []
        /// "Likely here now", before anything is typed: the field guides' birds the geomodel finds most likely at the
        /// photo's place and week, the likeliest first, without those heard.
        var likely: [NameableBird] = []
        /// "In your field guides": the matches among them, those heard this run or likely here first and the rest by common
        /// name; with nothing typed and no likely birds to suggest, all of them by name.
        var fieldGuide: [NameableBird] = []
        /// "All birds": the other matches in the same order, the first of them when there are many.
        var others: [NameableBird] = []
        /// How many more other birds matched than `others` lists.
        var moreOthers = 0

        /// Every bird listed, in the order the lists show them: for a caller with no sections to draw, as the lens (#194).
        var birds: [NameableBird] { heard + likely + fieldGuide + others }

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
        /// The bird's common names as they are said, for `spoken(_:in:limit:)`.
        let spoken: SpokenName.Names
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
            described.append(Entry(
                bird: bird, words: NameSearch.Words([entry.commonName, entry.scientificName, label?.commonName ?? ""]),
                spoken: SpokenName.Names([entry.commonName, label?.commonName ?? ""])
            ))
        }
        let rest = birds.filter { !seen.contains($0.scientificName) }.map { species in
            Entry(
                bird: NameableBird(speciesID: species.birdnetLabel, scientificName: species.scientificName, commonName: species.commonName, isInFieldGuide: false),
                words: NameSearch.Words([species.commonName, species.scientificName]),
                spoken: SpokenName.Names([species.commonName])
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
        guard !context.isEmpty else { return keep(context.standing(ofScientificName: "")) ? entries.map(\.bird) : [] }
        return entries.enumerated()
            .compactMap { position, entry -> (standing: Context.Standing, position: Int, bird: NameableBird)? in
                let standing = context.standing(ofScientificName: entry.bird.scientificName)
                return keep(standing) ? (standing, position, entry.bird) : nil
            }
            .sorted { $0.standing != $1.standing ? $0.standing < $1.standing : $0.position < $1.position }
            .map(\.bird)
    }

    /// The birds what was said to the glasses may name (issue #194), the closest first, at most `limit`: what the lens
    /// offers after a dictation. A recogniser does not write bird names as a birder types them, so the match is by the
    /// common name as it is said (`SpokenName`): the whole name or a run of its words, letter for letter, by ear, or a few
    /// sounds off. The words people say around a name ("it's a") are dropped.
    ///
    /// **What sounds the same comes first**: the whole name as written, the whole name by ear, a run of its words as
    /// written, then by ear. Birds as close as each other are in the order "Name this bird" lists a search in: one heard
    /// this run first, then one likely here, the likeliest first (`Context.Standing`), then the field guides' birds before
    /// the others, and by name. So "hummingbird" is the hummingbirds heard and likely here, and the bird that was named
    /// comes before a bird heard this run that is only near.
    ///
    /// **Then what is only near**, a few sounds off, the whole name before a part. Here where the bird stands counts
    /// before how near it is: among ten thousand names some bird of the wider world is always a sound nearer a slip of
    /// the tongue or the recogniser than the bird in front of the wearer ("annas" is nearer "Oasis" than "Allen's"). So a
    /// bird heard this run or likely here comes first, then the field guides' birds, then the rest, and within each the
    /// nearest first.
    func spoken(_ words: String, in context: Context = .none, limit: Int = 3) -> [NameableBird] {
        guard let said = SpokenName.said(words) else { return [] }
        /// A match, and where its bird stands: heard this run or likely here (0), in a field guide (1), neither (2).
        typealias Match = (closeness: SpokenName.Closeness, standing: Context.Standing, familiarity: Int, position: Int, bird: NameableBird)
        var found: [Match] = []
        // Each list is by name and the field guides' is first: the position across both is the last of the tie-breakers.
        for (position, entry) in (fieldGuide + others).enumerated() {
            guard let closeness = entry.spoken.closeness(to: said) else { continue }
            let standing = context.standing(ofScientificName: entry.bird.scientificName)
            found.append((closeness, standing, standing.isSuggested ? 0 : entry.bird.isInFieldGuide ? 1 : 2, position, entry.bird))
        }
        found.sort { lhs, rhs in
            let (one, other) = (lhs.closeness, rhs.closeness)
            if one.soundsTheSame != other.soundsTheSame { return one.soundsTheSame }
            if one.soundsTheSame {
                if one.rank != other.rank { return one.rank < other.rank }
            } else {
                if one.reach != other.reach { return one.reach == .name }
                if lhs.familiarity != rhs.familiarity { return lhs.familiarity < rhs.familiarity }
                if one.distance != other.distance { return one.distance < other.distance }
            }
            if lhs.standing != rhs.standing { return lhs.standing < rhs.standing }
            return lhs.position < rhs.position
        }
        return found.prefix(limit).map(\.bird)
    }

    /// The bird with this scientific name, if it can be named.
    func bird(scientificName: String) -> NameableBird? {
        byScientificName[scientificName]
    }
}

nonisolated extension NameableBirds.Context {
    /// What the run heard, and what the geomodel expects at the photo's place in the week it was taken. With no place the
    /// geomodel isn't asked and no bird is likely; a geomodel that can't be read leaves the same. Reading it is an inference,
    /// so this is called off the main actor.
    init(heard: [String], place: Coordinate?, takenAt: Date, occurrenceModel: any SpeciesOccurrenceModel, calendar: Calendar = .current) {
        self.init(heard: heard)
        guard let place else { return }
        do {
            occurrence = try occurrenceModel.occurrence(in: GeoContext(latitude: place.latitude, longitude: place.longitude, date: takenAt, calendar: calendar))
        } catch {
            Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "naming").error("no likely birds: \(error.localizedDescription, privacy: .public)")
        }
    }
}

nonisolated extension NameableBirds {
    /// The names over the packs on the phone and the bundled label list. Reading and splitting ten thousand names takes a
    /// moment, so this is called off the main actor.
    static func load(fieldGuide: [FieldGuideBird]) throws -> NameableBirds {
        NameableBirds(fieldGuide: fieldGuide, labels: try ONNXBirdModel.bundledLabels())
    }

    /// The same, for the app: if the bundled label list cannot be read, the field guides' birds alone. They are the
    /// birds a birder here most likely means and can still be named; the rest of the world's wait for a list that reads.
    static func loadOrFieldGuideOnly(fieldGuide: [FieldGuideBird]) -> NameableBirds {
        do {
            return try load(fieldGuide: fieldGuide)
        } catch {
            Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "naming").error("the label list did not load, naming from the field guides alone: \(error.localizedDescription, privacy: .public)")
            return NameableBirds(fieldGuide: fieldGuide, labels: [])
        }
    }
}

extension PackLibrary {
    /// Every species the packs on the phone describe, bundled first, for `NameableBirds`.
    var fieldGuideBirds: [NameableBirds.FieldGuideBird] {
        packs.flatMap { pack in pack.species.map { NameableBirds.FieldGuideBird(scientificName: $0.scientificName, commonName: $0.commonName) } }
    }
}
