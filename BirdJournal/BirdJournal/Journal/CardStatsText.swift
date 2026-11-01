import Foundation
import Pack

/// What a card prints of its species' stats (issue #55): wingspan, weight and diet on the front, habitat, migration,
/// nest, clutch and lifestyle on the back, and the datasets they came from. Units follow the phone's measurement
/// system: inches, feet, ounces and pounds under the US system, centimetres, metres, grams and kilograms otherwise (the
/// UK system included, since British birders measure birds in metric). A stat the pack lacks is left off.
enum CardStatsText {
    /// One stat: its label, the printed value, what VoiceOver reads, and an SF Symbol for the diet.
    struct Stat: Equatable {
        let label: String
        let value: String
        let spoken: String
        var symbol: String? = nil
    }

    /// Wingspan, weight and diet, each only when the pack has it.
    static func front(_ stats: PackStats, locale: Locale = .current) -> [Stat] {
        var shown: [Stat] = []
        if let wingspan = stats.wingspan {
            shown.append(Stat(label: "Wingspan", value: Self.wingspan(wingspan, locale: locale), spoken: wingspanSpoken(wingspan, locale: locale)))
        }
        if let grams = stats.massGrams {
            shown.append(Stat(label: "Weight", value: weight(grams: grams, locale: locale), spoken: "Weight \(mass(grams: grams, locale: locale).long)"))
        }
        if let diet = stats.diet {
            shown.append(Stat(label: "Diet", value: dietTitle(diet), spoken: dietSpoken(diet), symbol: dietSymbol(diet)))
        }
        return shown
    }

    /// Habitat, migration, nest, clutch and lifestyle, each only when the pack has it.
    static func back(_ stats: PackStats) -> [Stat] {
        let rows: [(String, String?)] = [
            ("Habitat", stats.habitat.map(habitatTitle)),
            ("Migration", stats.migration.map(migrationTitle)),
            ("Nest", stats.nests.isEmpty ? nil : nests(stats.nests)),
            ("Clutch", stats.clutch.map(clutch)),
            ("Lifestyle", stats.lifestyle.map(lifestyleTitle)),
        ]
        return rows.compactMap { label, value in value.map { Stat(label: label, value: $0, spoken: "\(label): \($0)") } }
    }

    // MARK: Units

    private static func isImperial(_ locale: Locale) -> Bool { locale.measurementSystem == .us }

    private static func number(_ value: Double, fractionDigits: Int, locale: Locale) -> String {
        value.formatted(.number.precision(.fractionLength(fractionDigits)).locale(locale))
    }

    /// The printed length and its spelled-out form: "23 cm" / "23 centimetres", "6.7 ft" / "6.7 feet".
    private static func length(centimetres: Double, locale: Locale) -> (short: String, long: String) {
        if isImperial(locale) {
            let inches = centimetres / 2.54
            if inches >= 48 {
                let feet = number(inches / 12, fractionDigits: 1, locale: locale)
                return ("\(feet) ft", "\(feet) feet")
            }
            let whole = number(inches, fractionDigits: 0, locale: locale)
            return ("\(whole) in", "\(whole) \(whole == "1" ? "inch" : "inches")")
        }
        let spelling = locale.region == .unitedStates ? "er" : "re"
        if centimetres >= 100 {
            let metres = number(centimetres / 100, fractionDigits: 1, locale: locale)
            return ("\(metres) m", "\(metres) met\(spelling)s")
        }
        let whole = number(centimetres, fractionDigits: 0, locale: locale)
        return ("\(whole) cm", "\(whole) centimet\(spelling)s")
    }

    /// "23 cm", or "≈ 23 cm" when the wingspan database predicted it from wing length.
    static func wingspan(_ wingspan: PackStats.Wingspan, locale: Locale = .current) -> String {
        let printed = length(centimetres: wingspan.centimetres, locale: locale).short
        return wingspan.isPredicted ? "≈ \(printed)" : printed
    }

    /// "Wingspan 23 centimetres", or "Wingspan about 23 centimetres, estimated from wing length": VoiceOver would read
    /// "≈" as "almost equal to".
    static func wingspanSpoken(_ wingspan: PackStats.Wingspan, locale: Locale = .current) -> String {
        let spoken = length(centimetres: wingspan.centimetres, locale: locale).long
        return wingspan.isPredicted ? "Wingspan about \(spoken), estimated from wing length" : "Wingspan \(spoken)"
    }

    /// The printed weight and its spelled-out form: "21 g" / "21 grams", "2.4 lb" / "2.4 pounds".
    private static func mass(grams: Double, locale: Locale) -> (short: String, long: String) {
        if isImperial(locale) {
            let ounces = grams / 28.349523125
            if ounces >= 16 {
                let pounds = number(ounces / 16, fractionDigits: 1, locale: locale)
                return ("\(pounds) lb", "\(pounds) pounds")
            }
            let value = number(ounces, fractionDigits: ounces < 1 ? 2 : 1, locale: locale)
            return ("\(value) oz", "\(value) ounces")
        }
        if grams >= 1000 {
            let kilograms = number(grams / 1000, fractionDigits: 1, locale: locale)
            return ("\(kilograms) kg", "\(kilograms) kilograms")
        }
        let value = number(grams, fractionDigits: grams < 10 ? 1 : 0, locale: locale)
        return ("\(value) g", "\(value) grams")
    }

    /// "4.2 g", "21 g", "1.1 kg"; "0.15 oz", "0.75 oz", "2.4 lb".
    static func weight(grams: Double, locale: Locale = .current) -> String {
        mass(grams: grams, locale: locale).short
    }

    // MARK: Words

    static func dietTitle(_ diet: PackStats.Diet) -> String {
        switch diet {
        case .frugivore: "Fruit"
        case .granivore: "Seeds"
        case .nectarivore: "Nectar"
        case .invertivore: "Insects"
        case .vertivore: "Small animals"
        case .scavenger: "Carrion"
        case .omnivore: "Omnivore"
        case .herbivoreTerrestrial: "Plants"
        case .herbivoreAquatic: "Water plants"
        case .aquaticPredator: "Fish"
        }
    }

    /// The diet icon's VoiceOver label, a little fuller than the printed word.
    static func dietSpoken(_ diet: PackStats.Diet) -> String {
        let food = switch diet {
        case .frugivore: "mostly fruit"
        case .granivore: "mostly seeds"
        case .nectarivore: "mostly nectar"
        case .invertivore: "insects and other invertebrates"
        case .vertivore: "small animals"
        case .scavenger: "carrion and scraps"
        case .omnivore: "a bit of everything"
        case .herbivoreTerrestrial: "plants"
        case .herbivoreAquatic: "water plants"
        case .aquaticPredator: "fish and other water life"
        }
        return "Diet: \(food)"
    }

    static func dietSymbol(_ diet: PackStats.Diet) -> String {
        switch diet {
        case .frugivore: "tree"
        case .granivore: "laurel.leading"
        case .nectarivore: "camera.macro"
        case .invertivore: "ant"
        case .vertivore: "hare"
        case .scavenger: "pawprint"
        case .omnivore: "fork.knife"
        case .herbivoreTerrestrial: "leaf"
        case .herbivoreAquatic: "water.waves"
        case .aquaticPredator: "fish"
        }
    }

    static func habitatTitle(_ habitat: PackStats.Habitat) -> String {
        switch habitat {
        case .desert: "Desert"
        case .grassland: "Grassland"
        case .shrubland: "Shrubland"
        case .woodland: "Woodland"
        case .forest: "Forest"
        case .wetland: "Wetland"
        case .riverine: "Rivers and streams"
        case .coastal: "Coast"
        case .marine: "Open sea"
        case .rock: "Rocky ground"
        case .humanModified: "Towns and farmland"
        }
    }

    static func migrationTitle(_ migration: PackStats.Migration) -> String {
        switch migration {
        case .resident: "Resident"
        case .partialMigrant: "Partial migrant"
        case .migrant: "Migrant"
        }
    }

    static func lifestyleTitle(_ lifestyle: PackStats.Lifestyle) -> String {
        switch lifestyle {
        case .aerial: "Feeds on the wing"
        case .terrestrial: "Lives on the ground"
        case .insessorial: "Perches in trees and shrubs"
        case .aquatic: "Lives on the water"
        case .generalist: "Generalist"
        }
    }

    private static func nestTitle(_ nest: PackStats.Nest) -> String {
        switch nest {
        case .burrow: "burrow"
        case .cup: "cup"
        case .crevice: "crevice"
        case .cavity: "tree cavity"
        case .dome: "dome"
        case .platform: "platform"
        case .pendant: "hanging pouch"
        case .saucer: "saucer"
        case .scrape: "scrape on the ground"
        case .sphere: "sphere"
        case .mound: "mound"
        case .halfCup: "half cup"
        case .noNest: "no nest"
        case .otherNest: "other birds' nests"
        }
    }

    /// "Half cup, cup or platform".
    static func nests(_ nests: [PackStats.Nest]) -> String {
        let joined = list(nests.map(nestTitle), conjunction: "or")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    /// "a, b and c" (no serial comma, as the rest of the app writes lists).
    private static func list(_ words: [String], conjunction: String) -> String {
        guard let last = words.last, words.count > 1 else { return words.joined() }
        return words.dropLast().joined(separator: ", ") + " \(conjunction) " + last
    }

    /// "2–7 eggs", "2 eggs", "1 egg".
    static func clutch(_ clutch: ClosedRange<Double>) -> String {
        func count(_ value: Double) -> String {
            value.formatted(.number.precision(.fractionLength(0...1)).locale(Locale(identifier: "en_US_POSIX")))
        }
        let text = clutch.lowerBound == clutch.upperBound ? count(clutch.lowerBound) : "\(count(clutch.lowerBound))–\(count(clutch.upperBound))"
        return "\(text) \(clutch.upperBound == 1 ? "egg" : "eggs")"
    }

    /// The datasets this species' stats came from, by name, with their license; "≈" explained when it shows.
    static func sources(_ stats: PackStats) -> String {
        let names = StatsDataset.all.filter { stats.sources.contains($0.source) }.map { $0.source == .wingspan ? "the \($0.name)" : $0.name }
        let joined = list(names, conjunction: "and")
        let estimate = stats.wingspan?.isPredicted == true ? " A wingspan marked ≈ is estimated from wing length." : ""
        return "From \(joined) (\(StatsDataset.license)).\(estimate)"
    }
}
