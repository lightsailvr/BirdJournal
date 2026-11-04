import Album
import Foundation
import Pack

/// What patches say in words (issue #134, guide pages 6, 10 and 14). VoiceOver reads a patch as one sentence: its name, its
/// edition, its count and when it was sewn.
enum PatchText {
    /// "House Finch, Citrus edition patch, seen 8 times, sewn September 14, 2026"; "House Finch, Uncharted patch, …".
    static func spoken(_ patch: CardCollection.Patch, name: String) -> String {
        let sewn = patch.sewn.confirmedAt.formatted(date: .long, time: .omitted)
        return "\(name), \(patch.placement.editionLabel) patch, seen \(CardCollection.Patch.times(patch.count)), sewn \(sewn)"
    }

    /// "Northern Mockingbird, number 9 of 160, not yet found".
    static func spokenPattern(name: String, number: Int, total: Int) -> String {
        "\(name), number \(number) of \(total), not yet found"
    }

    /// A board tile's line under the name: "No. 003 · seen 8×", or "seen 3×" outside every set.
    static func tileLine(_ patch: CardCollection.Patch) -> String {
        guard case .numbered(_, _, _, let number, let total) = patch.placement else { return "seen \(patch.count)×" }
        return "No. \(CardPlacement.paddedNumber(number, of: total)) · seen \(patch.count)×"
    }

    /// A pattern's line under the name: "No. 009".
    static func patternLine(number: Int, total: Int) -> String {
        "No. \(CardPlacement.paddedNumber(number, of: total))"
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
