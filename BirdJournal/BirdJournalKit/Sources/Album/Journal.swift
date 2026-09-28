import Foundation

/// The journal's reading of the album (issue #28): sightings grouped by day, the distinct species among them, and
/// the search rule. Pure functions over fetched sightings, so the screens stay thin and the rules are tested here.
public enum Journal {
    /// One day of the Sightings list: the day's start and its sightings, newest first.
    public struct Day: Identifiable, Equatable {
        public let start: Date
        public let sightings: [Sighting]

        public var id: Date { start }

        public init(start: Date, sightings: [Sighting]) {
            self.start = start
            self.sightings = sightings
        }

        public static func == (lhs: Day, rhs: Day) -> Bool {
            lhs.start == rhs.start && lhs.sightings.map(\.persistentModelID) == rhs.sightings.map(\.persistentModelID)
        }
    }

    /// One row of the Species list: a species the birder has added, how often, and its latest sighting.
    public struct SpeciesEntry: Identifiable, Equatable {
        /// The BirdNET label.
        public let speciesID: String
        public let count: Int
        public let latest: Sighting

        public var id: String { speciesID }
        public var scientificName: String { latest.scientificName }
        public var commonName: String { latest.commonName }

        public static func == (lhs: SpeciesEntry, rhs: SpeciesEntry) -> Bool {
            lhs.speciesID == rhs.speciesID && lhs.count == rhs.count && lhs.latest.persistentModelID == rhs.latest.persistentModelID
        }
    }

    /// Groups sightings by calendar day, newest day first and newest sighting first within a day, whatever order
    /// they arrive in.
    public static func days(_ sightings: [Sighting], calendar: Calendar = .current) -> [Day] {
        let grouped = Dictionary(grouping: sightings) { calendar.startOfDay(for: $0.confirmedAt) }
        return grouped
            .map { Day(start: $0.key, sightings: $0.value.sorted { $0.confirmedAt > $1.confirmedAt }) }
            .sorted { $0.start > $1.start }
    }

    /// The day's heading: "Today", "Yesterday", the weekday and date within the week, else the date; this year's
    /// dates leave the year out.
    public static func title(for day: Date, now: Date = .now, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let today = calendar.startOfDay(for: now)
        let start = calendar.startOfDay(for: day)
        let daysAgo = calendar.dateComponents([.day], from: start, to: today).day ?? 0
        var format = Date.FormatStyle(locale: locale, calendar: calendar).month(.wide).day()
        if calendar.component(.year, from: start) != calendar.component(.year, from: today) {
            format = format.year()
        }
        switch daysAgo {
        case 0: return "Today, \(day.formatted(format))"
        case 1: return "Yesterday"
        case 2...6: return day.formatted(format.weekday(.wide))
        default: return day.formatted(format)
        }
    }

    /// The distinct species among `sightings`, each with its count and latest sighting, latest first.
    public static func species(_ sightings: [Sighting]) -> [SpeciesEntry] {
        let grouped = Dictionary(grouping: sightings, by: \.speciesID)
        return grouped
            .compactMap { id, group -> SpeciesEntry? in
                guard let latest = group.max(by: { $0.confirmedAt < $1.confirmedAt }) else { return nil }
                return SpeciesEntry(speciesID: id, count: group.count, latest: latest)
            }
            .sorted { $0.latest.confirmedAt > $1.latest.confirmedAt }
    }

    /// The summary line under the journal's title, e.g. "12 species · 28 sightings".
    public static func summary(sightingCount: Int, speciesCount: Int) -> String {
        "\(speciesCount) species · \(sightingCount) \(sightingCount == 1 ? "sighting" : "sightings")"
    }

    /// Whether a species matches a search: every word of the query starts a word of the common or scientific name,
    /// ignoring case and accents, so "phoe" finds the Black Phoebe and "sayo nig" does too. An empty query matches.
    public static func matches(query: String, commonName: String, scientificName: String) -> Bool {
        NameSearch.matches(query: query, in: [commonName, scientificName])
    }
}

/// The search rule the journal, the guide and the packs share: every word of the query starts a word of one of the
/// names, ignoring case and accents. An empty query matches everything.
public enum NameSearch {
    public static func matches(query: String, in names: [String]) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace).map(normalize)
        guard !terms.isEmpty else { return true }
        let words = names.joined(separator: " ")
            .split { !$0.isLetter && !$0.isNumber && $0 != "'" }
            .map { normalize(String($0)) }
        return terms.allSatisfy { term in words.contains { $0.hasPrefix(term) } }
    }

    private static func normalize<S: StringProtocol>(_ text: S) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
