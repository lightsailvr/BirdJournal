import Foundation

/// A species' card stats (issue #55), as the pack builder joins them from three CC BY 4.0 datasets: AVONET (mass,
/// habitat, migration, trophic niche and primary lifestyle), BIRDBASE (nest, clutch) and the avian wingspan database
/// (a measured wingspan, else a predicted one). A stat the datasets lack is nil, never guessed.
public struct PackStats: Sendable, Hashable {
    public struct Wingspan: Sendable, Hashable {
        public let centimetres: Double
        /// The database's estimate from wing length rather than a measurement: the card shows "≈".
        public let isPredicted: Bool

        public init(centimetres: Double, isPredicted: Bool) {
            self.centimetres = centimetres
            self.isPredicted = isPredicted
        }
    }

    /// AVONET's trophic niche: what the bird mostly eats (60 % or more of its food), or Omnivore.
    public enum Diet: String, Sendable, Hashable, CaseIterable {
        case frugivore, granivore, nectarivore, invertivore, vertivore, scavenger, omnivore
        case herbivoreTerrestrial = "herbivore_terrestrial"
        case herbivoreAquatic = "herbivore_aquatic"
        case aquaticPredator = "aquatic_predator"
    }

    /// AVONET's primary habitat.
    public enum Habitat: String, Sendable, Hashable, CaseIterable {
        case desert, grassland, shrubland, woodland, forest, wetland, riverine, coastal, marine, rock
        case humanModified = "human_modified"
    }

    /// AVONET's migration: sedentary, partially migratory or migratory.
    public enum Migration: String, Sendable, Hashable, CaseIterable {
        case resident, migrant
        case partialMigrant = "partial_migrant"
    }

    /// AVONET's primary lifestyle: where the bird spends its time and forages.
    public enum Lifestyle: String, Sendable, Hashable, CaseIterable {
        case aerial, terrestrial, insessorial, aquatic, generalist
    }

    /// BIRDBASE's nest types.
    public enum Nest: String, Sendable, Hashable, CaseIterable {
        case burrow, cup, crevice, cavity, dome, platform, pendant, saucer, scrape, sphere, mound
        case halfCup = "half_cup"
        /// Lays without a nest.
        case noNest = "no_nest"
        /// In another bird's nest: a brood parasite.
        case otherNest = "other_nest"
    }

    /// The datasets that gave this species a value.
    public enum Source: String, Sendable, Hashable, CaseIterable {
        case avonet, birdbase, wingspan
    }

    public let avibaseID: String?
    public let wingspan: Wingspan?
    public let massGrams: Double?
    public let diet: Diet?
    public let habitat: Habitat?
    public let migration: Migration?
    /// The nest types BIRDBASE lists, in its order; empty when it has none.
    public let nests: [Nest]
    /// Eggs per clutch.
    public let clutch: ClosedRange<Double>?
    public let lifestyle: Lifestyle?
    public let sources: [Source]

    public init(
        avibaseID: String?, wingspan: Wingspan?, massGrams: Double?, diet: Diet?, habitat: Habitat?, migration: Migration?, nests: [Nest],
        clutch: ClosedRange<Double>?, lifestyle: Lifestyle?, sources: [Source]
    ) {
        self.avibaseID = avibaseID
        self.wingspan = wingspan
        self.massGrams = massGrams
        self.diet = diet
        self.habitat = habitat
        self.migration = migration
        self.nests = nests
        self.clutch = clutch
        self.lifestyle = lifestyle
        self.sources = sources
    }
}

/// A card's family line in a trading-card style, "Songbird — Finch": a group word for the order and a family word,
/// from the pack builder's hand-written mappings.
public struct PackTypeLine: Sendable, Hashable {
    public let order: String
    public let family: String
    public let groupWord: String
    public let familyWord: String

    public init(order: String, family: String, groupWord: String, familyWord: String) {
        self.order = order
        self.family = family
        self.groupWord = groupWord
        self.familyWord = familyWord
    }

    public var text: String { "\(groupWord) — \(familyWord)" }
}

/// The three datasets behind the card stats, for the credits screen and the card back (issue #55). All CC BY 4.0.
public struct StatsDataset: Sendable, Hashable, Identifiable {
    public let source: PackStats.Source
    public let name: String
    public let citation: String
    public let url: URL
    public static let license = "CC BY 4.0"
    public static let licenseURL = URL(string: "https://creativecommons.org/licenses/by/4.0/")!

    public var id: PackStats.Source { source }

    /// In the order the pack LICENSE lists them (`packbuilder.stats.DATASETS`).
    public static let all: [StatsDataset] = [
        StatsDataset(
            source: .avonet, name: "AVONET",
            citation: "Tobias, J.A. et al. (2022) AVONET: morphological, ecological and geographical data for all birds. Ecology Letters 25, 581–597.",
            url: URL(string: "https://doi.org/10.6084/m9.figshare.16586228.v7")!
        ),
        StatsDataset(
            source: .birdbase, name: "BIRDBASE",
            citation: "Şekercioğlu, Ç.H. et al. (2025) BIRDBASE: a global dataset of avian biogeography, conservation, ecology and life history traits. Scientific Data 12 (v2025.1).",
            url: URL(string: "https://doi.org/10.6084/m9.figshare.27051040.v1")!
        ),
        StatsDataset(
            source: .wingspan, name: "Avian wingspan database",
            citation: "Fox, M.R., Brunton, E.A. and Shephard, J.M. (2026) Avian wingspan database: empirical and predicted wingspan for 10,618 flighted bird species.",
            url: URL(string: "https://doi.org/10.6084/m9.figshare.32089083.v1")!
        ),
    ]
}
