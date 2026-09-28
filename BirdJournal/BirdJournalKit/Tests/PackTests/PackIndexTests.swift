import Foundation
import Testing
@testable import Pack

@Suite("PackIndex")
struct PackIndexTests {
    @Test("decodes the GitHub Releases pack index")
    func decodesIndex() throws {
        let json = """
        {
          "packs": [
            {
              "id": "us-ca-la",
              "name": "Los Angeles",
              "version": 3,
              "url": "https://github.com/lightsailvr/BirdJournal/releases/download/pack-us-ca-la-3/us-ca-la.zip",
              "sha256": "0000000000000000000000000000000000000000000000000000000000000000",
              "byteCount": 12345678
            }
          ]
        }
        """

        let index = try PackIndex.decode(from: Data(json.utf8))

        #expect(index.packs.count == 1)
        let pack = try #require(index.packs.first)
        #expect(pack.id == "us-ca-la")
        #expect(pack.name == "Los Angeles")
        #expect(pack.version == 3)
        #expect(pack.url.host() == "github.com")
        #expect(pack.byteCount == 12_345_678)
    }

}

extension PackIndexTests {
    @Test("an index with counts and a region decodes them, and one without leaves them nil (issue #28)")
    func decodesOptionalFacts() throws {
        let json = """
        {"packs": [
          {"id": "us-ca-sd", "name": "San Diego", "version": 2, "url": "https://example.com/sd.zip", "sha256": "ab", "byteCount": 10,
           "speciesCount": 40, "photoCount": 200, "region": "San Diego County, California, US"},
          {"id": "old", "name": "Old", "version": 1, "url": "https://example.com/old.zip", "sha256": "cd", "byteCount": 5}
        ]}
        """

        let index = try PackIndex.decode(from: Data(json.utf8))

        #expect(index.packs[0].speciesCount == 40)
        #expect(index.packs[0].photoCount == 200)
        #expect(index.packs[0].region == "San Diego County, California, US")
        #expect(index.packs[1].speciesCount == nil && index.packs[1].photoCount == nil && index.packs[1].region == nil)
    }
}
