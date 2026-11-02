import Foundation
import Testing
@testable import Pack

/// Card stats and the type line (issue #55): schema-4 packs carry each species' stats from AVONET, BIRDBASE and the
/// avian wingspan database, its threatened flag and its type line; a known gap has no stats, an older pack none of
/// them, and the bundled Los Angeles pack has them for every species.
@Suite("PackStats")
@MainActor
struct PackStatsTests {
    @Test("a species' stats, type line and threatened flag read as the builder wrote them")
    func fixtureStats() throws {
        let root = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let pack = try PackSetTests.install("test-pack", root: root)

        let phoebe = try #require(pack.species(scientificName: "Sayornis nigricans"))
        let stats = try #require(phoebe.stats)
        #expect(stats.wingspan == PackStats.Wingspan(centimetres: 27.5, isPredicted: true))
        #expect(stats.massGrams == 18.6)
        #expect(stats.diet == .invertivore)
        #expect(stats.habitat == .riverine)
        #expect(stats.migration == .resident)
        #expect(stats.nests == [.halfCup, .cup])
        #expect(stats.clutch == 3...6)
        #expect(stats.lifestyle == .insessorial)
        #expect(stats.sources == [.avonet, .birdbase, .wingspan])
        #expect(phoebe.typeLine?.text == "Songbird — Phoebe")
        #expect(phoebe.isThreatened == false)

        let hummingbird = try #require(pack.species(scientificName: "Calypte anna"))
        #expect(hummingbird.stats == nil, "a known gap has no stats")
        #expect(hummingbird.typeLine?.text == "Landbird — Hummingbird")
        #expect(hummingbird.isThreatened == true)
    }

    @Test("a schema-3 pack has no stats, type lines or threatened flags")
    func olderPack() throws {
        let root = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let pack = try PackSetTests.install("test-pack-schema3", root: root)
        for species in pack.species {
            #expect(species.stats == nil && species.typeLine == nil && species.isThreatened == nil)
        }
    }

    @Test(
        "the bundled pack's House Wren reuses old nests and is no brood parasite; the cowbird and the whydah are (#86)",
        .enabled(if: (try? SpeciesPack.bundled().info.version) ?? 0 >= 9, "the bundled pack predates the nest fix")
    )
    func bundledNestReuseAndBroodParasites() throws {
        let pack = try SpeciesPack.bundled()
        let wren = try #require(pack.species(scientificName: "Troglodytes aedon"))
        #expect(wren.stats?.nests == [.cavity, .otherNest, .crevice])
        let told = wren.facts.map(\.text) + [wren.lore?.text, wren.lore?.tagline].compactMap { $0 }
        #expect(!told.contains { $0.contains("parasite") || $0.contains("other birds' nests") }, "\(told)")
        let parasites = pack.species.filter { $0.stats?.nests.contains(.broodParasite) == true }.map(\.scientificName)
        #expect(Set(parasites) == ["Molothrus ater", "Vidua macroura"])
        #expect(pack.species.allSatisfy { $0.stats?.nests.contains(.broodParasite) != true || $0.stats?.nests == [.broodParasite] })
    }

    @Test("every species in the bundled Los Angeles pack has stats or is a listed gap, and has a type line")
    func bundledPackStats() throws {
        let pack = try SpeciesPack.bundled()
        let gaps = try SpeciesPackTests.gaps(in: pack, key: "stats")
        for species in pack.species {
            #expect(species.stats != nil || gaps.contains(species.id), "\(species.commonName) has no stats and is not a listed gap")
            let typeLine = try #require(species.typeLine, "\(species.commonName) has no type line")
            #expect(!typeLine.groupWord.isEmpty && !typeLine.familyWord.isEmpty)
            #expect(species.isThreatened != nil, "\(species.commonName) has no threatened row")
            if let stats = species.stats {
                #expect(stats.massGrams.map { $0 > 0 } ?? true, "\(species.commonName)")
                #expect(stats.diet != nil, "\(species.commonName) has no diet")
                #expect(stats.sources.contains(.avonet))
                #expect(stats.wingspan == nil || stats.sources.contains(.wingspan))
            }
        }
        #expect(pack.species(scientificName: "Haemorhous mexicanus")?.typeLine?.text == "Songbird — Finch")
        #expect(pack.species(scientificName: "Buteo jamaicensis")?.typeLine?.text == "Raptor — Hawk")
        let wingspans = pack.species.compactMap { $0.stats?.wingspan }
        #expect(wingspans.count * 10 >= pack.species.count * 9, "only \(wingspans.count) of \(pack.species.count) species have a wingspan")
        #expect(wingspans.contains { !$0.isPredicted } && wingspans.contains(where: \.isPredicted))
        #expect(pack.species(scientificName: "Polioptila californica")?.isThreatened == true, "the hand list")
        #expect(pack.info.licenseText.contains("AVONET") && pack.info.licenseText.contains("BIRDBASE") && pack.info.licenseText.contains("Avian wingspan database"))
    }
}
