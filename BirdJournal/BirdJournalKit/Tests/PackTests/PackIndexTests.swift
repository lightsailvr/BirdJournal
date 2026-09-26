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

    @Test("the bundled pack is the Los Angeles pack")
    func bundledPack() {
        #expect(PackIndex.bundledPackID == "us-ca-la")
    }
}
