import Album
import Foundation
import Pack

/// What patches say in words (issue #134, guide pages 6, 10 and 14). VoiceOver reads a patch as one sentence: its name, its
/// edition, its count and when it was sewn.
enum PatchText {
    /// "House Finch, Citrus edition patch, seen 8 times, sewn September 14"; "House Finch, Uncharted patch, …". Its painting
    /// on its way, it ends ", art on its way": what the blank's "Being sewn" means, which "sewn …, being sewn" wouldn't say.
    static func spoken(_ patch: CardCollection.Patch, name: String, beingSewn: Bool = false) -> String {
        spoken(name: name, edition: patch.placement.editionLabel, count: patch.count, sewn: patch.sewn.confirmedAt, beingSewn: beingSewn)
    }

    /// The same sentence for a patch that isn't read from the collection: the one just sewn.
    static func spoken(name: String, edition: String, count: Int, sewn: Date, beingSewn: Bool = false, now: Date = .now) -> String {
        "\(name), \(edition) patch, seen \(CardCollection.Patch.times(count)), sewn \(spokenDate(sewn, now: now))\(beingSewn ? ", art on its way" : "")"
    }

    /// "September 14", with the year only when it isn't this year's.
    static func spokenDate(_ date: Date, now: Date = .now) -> String {
        Calendar.current.isDate(date, equalTo: now, toGranularity: .year) ? date.formatted(.dateTime.month(.wide).day()) : date.formatted(date: .long, time: .omitted)
    }

    /// The paper card's edition line: a set's edition, or Uncharted as the guide writes it (page 15).
    static func cardEdition(_ placement: CardPlacement) -> String {
        placement.setID == nil ? "\(CardPlacement.unchartedTitle) · outside every set" : placement.editionLabel
    }

    /// A bird's place in a set: what's shown, and what VoiceOver reads.
    struct SetNumber: Hashable {
        let text: String
        let spoken: String
    }

    /// A bird not yet found, by its place in every set that lists it: "No. 021 of 160 · Los Angeles".
    static func setNumbers(of scientificName: String, in sets: [PackSet]) -> [SetNumber] {
        sets.compactMap { set in
            set.species.firstIndex { $0.scientificName == scientificName }.map { index in
                SetNumber(text: numberLine(index + 1, of: set.species.count, in: set.name), spoken: "Number \(index + 1) of \(set.species.count) in \(set.name)")
            }
        }
    }

    /// "No. 021 of 160 · Los Angeles".
    private static func numberLine(_ number: Int, of total: Int, in setName: String) -> String {
        "No. \(CardPlacement.paddedNumber(number, of: total)) of \(total) · \(setName)"
    }

    /// Under the name on the reveal: "No. 019 of 160 · Los Angeles"; nil outside every set.
    static func revealNumberLine(_ placement: CardPlacement) -> String? {
        guard case .numbered(_, let setName, _, let number, let total) = placement else { return nil }
        return numberLine(number, of: total, in: setName)
    }

    /// A latest sighting's date on the seen-again page: "Today · 8:03 AM", else "Oct 30".
    static func latestDate(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today · \(date.formatted(date: .omitted, time: .shortened))" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// Under the latest sightings: "+ 5 earlier · Sewn Sep 14", or "Sewn Sep 14" when they were all shown.
    static func earlierLine(_ patch: CardCollection.Patch, shown: Int) -> String {
        let sewn = "Sewn \(patch.sewn.confirmedAt.formatted(.dateTime.month(.abbreviated).day()))"
        return patch.count > shown ? "+ \(patch.count - shown) earlier · \(sewn)" : sewn
    }

    /// A board tile's line under the name: "No. 003 · seen 8×", or "seen 3×" outside every set.
    static func tileLine(_ patch: CardCollection.Patch) -> String {
        guard case .numbered(_, _, _, let number, let total) = patch.placement else { return "seen \(patch.count)×" }
        return "No. \(CardPlacement.paddedNumber(number, of: total)) · seen \(patch.count)×"
    }

    /// Under the patch on its page: "Seen 8 times in Los Angeles · sewn Sep 14".
    static func pageLine(_ patch: CardCollection.Patch) -> String {
        "\(patch.seenAgainText) · sewn \(patch.sewn.confirmedAt.formatted(.dateTime.month(.abbreviated).day()))"
    }

    /// The edition line over the name: "CITRUS EDITION · NO. 003", or "UNCHARTED" (the view sets the capitals).
    static func editionLine(_ placement: CardPlacement) -> String {
        guard case .numbered(_, _, let edition, let number, let total) = placement else { return CardPlacement.unchartedTitle }
        return "\(edition) · No. \(CardPlacement.paddedNumber(number, of: total))"
    }

    /// The name a patch goes by: a pack's, else the label's own, so a bird no pack describes is still named.
    @MainActor
    static func name(of patch: CardCollection.Patch, library: PackLibrary) -> String {
        library.species(scientificName: patch.scientificName)?.species.commonName ?? BirdComparison.commonName(ofLabel: patch.speciesID)
    }

    /// "1 sighting", "8 sightings".
    static func sightings(_ count: Int) -> String {
        "\(count) \(count == 1 ? "sighting" : "sightings")"
    }

    /// What's left of the lore after the card's excerpt: it opens below on scroll, without repeating it; nil when the
    /// excerpt took it all.
    static func restOfLore(_ lore: String) -> String? {
        guard let excerpt = LoreExcerpt.front(lore), lore.hasPrefix(excerpt) else { return nil }
        return String(lore.dropFirst(excerpt.count)).trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// The paper card's biology (guide page 10), each only when the pack has it: wingspan (≈ where estimated), weight,
    /// diet, nest, clutch and size.
    static func biology(_ species: PackSpecies?) -> [CardStatsText.Stat] {
        guard let species else { return [] }
        var stats = species.stats.map { CardStatsText.front($0) } ?? []
        let back = species.stats.map { CardStatsText.back($0) } ?? []
        stats += back.filter { ["Nest", "Clutch"].contains($0.label) }
        if let size = species.size?.nilIfEmpty {
            stats.append(CardStatsText.Stat(label: "Size", value: size, spoken: "Size: \(size)"))
        }
        return stats
    }
}
