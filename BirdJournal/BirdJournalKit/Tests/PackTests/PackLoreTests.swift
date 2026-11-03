import Foundation
import Testing
@testable import Pack

/// The fact sheet and lore (issue #56): a schema-4 pack carries each species' sourced facts and its reviewed lore with
/// a tagline; an older pack has neither, and the bundled Los Angeles pack has lore for every species once its lore
/// lock is filled and the pack rebuilt (version 7, the build that ships #57's art and this lore together). Since #113 the
/// lore carries an approved story title; a pack built before has none.
@Suite("PackLore")
@MainActor
struct PackLoreTests {
    /// The first Los Angeles version built with lore.
    nonisolated static let firstLoreVersion = 7
    /// The first Los Angeles version built with story titles (#113).
    nonisolated static let firstTitleVersion = 10

    @Test("a species' fact sheet and lore read as the builder wrote them; a species without approved lore has none")
    func fixtureLore() throws {
        let root = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let pack = try PackSetTests.install("test-pack", root: root)
        let revision = URL(string: "https://en.wikipedia.org/w/index.php?title=Black_phoebe&oldid=1361402245")!

        let phoebe = try #require(pack.species(scientificName: "Sayornis nigricans"))
        #expect(phoebe.facts.map(\.text) == [
            "It feeds mostly on insects and other invertebrates.",
            "The black phoebe hunts from a low perch, flying out to catch insects in the air.",
        ])
        #expect(phoebe.facts.map(\.dataset) == [.avonet, nil])
        #expect(phoebe.facts[1].wikipediaRevision == revision)
        let lore = try #require(phoebe.lore)
        #expect(lore.text.hasPrefix("Where water runs, the dark sentinel"))
        #expect(lore.tagline == "Keeper of the low perch.")
        #expect(lore.title == "The Waterside Sentinel")
        #expect(lore.wikipediaRevision == revision)
        #expect(lore.datasets == [.avonet])

        let hummingbird = try #require(pack.species(scientificName: "Calypte anna"))
        #expect(hummingbird.facts.map(\.text) == ["It feeds mostly on nectar."])
        #expect(hummingbird.lore == nil)
        #expect(pack.info.licenseText.contains("written from the fact sheet alone by Claude"))
    }

    @Test("a schema-4 pack from before story titles reads its lore with no title")
    func untitledPack() throws {
        let root = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let pack = try PackSetTests.install("test-pack-untitled", root: root)
        #expect(pack.info.schemaVersion == 4)
        let lore = try #require(pack.species(scientificName: "Sayornis nigricans")?.lore)
        #expect(lore.tagline == "Keeper of the low perch.")
        #expect(lore.title == nil)
    }

    @Test("a schema-3 pack has no fact sheet and no lore")
    func olderPack() throws {
        let root = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let pack = try PackSetTests.install("test-pack-schema3", root: root)
        #expect(pack.species.allSatisfy { $0.facts.isEmpty && $0.lore == nil })
    }

    @Test(
        "every Los Angeles species has a fact sheet, lore and a tagline, crediting its Wikipedia revision",
        .enabled(if: (try? SpeciesPack.bundled().info.version) ?? 0 >= firstLoreVersion, "the bundled pack predates the lore build")
    )
    func bundledLore() throws {
        let pack = try SpeciesPack.bundled()
        for species in pack.species {
            #expect(!species.facts.isEmpty, "\(species.commonName) has no fact sheet")
            let lore = try #require(species.lore, "\(species.commonName) has no lore")
            let words = lore.text.split(separator: " ").count
            #expect((50...80).contains(words), "\(species.commonName)'s lore is \(words) words")
            #expect((1...12).contains(lore.tagline.split(separator: " ").count), "\(species.commonName)'s tagline")
            if let revision = lore.wikipediaRevision {
                #expect(species.descriptionSource == revision, "\(species.commonName)'s lore credits another revision than its description")
            }
        }
        #expect(pack.info.licenseText.contains("written from the fact sheet alone by Claude"))
    }

    @Test(
        "every Los Angeles species has a story title of 2 to 5 words",
        .enabled(if: (try? SpeciesPack.bundled().info.version) ?? 0 >= firstTitleVersion, "the bundled pack predates the story titles")
    )
    func bundledTitles() throws {
        let pack = try SpeciesPack.bundled()
        for species in pack.species {
            let title = try #require(species.lore?.title, "\(species.commonName) has no story title")
            #expect((2...5).contains(title.split(separator: " ").count), "\(species.commonName)'s title is \(title)")
            #expect(!title.localizedCaseInsensitiveContains(species.commonName), "\(species.commonName)'s title names it")
        }
    }
}
