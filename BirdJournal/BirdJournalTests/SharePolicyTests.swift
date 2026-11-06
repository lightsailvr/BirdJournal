import Album
import Foundation
import ImageIO
import Pack
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import BirdJournal

// Issue #28: what a shared sighting carries. The precise location never does; the picture's credit always does;
// a photo whose license does not allow redistribution is left out.
@Suite("Share policy")
struct SharePolicyTests {
    static let sighting = Sighting(
        speciesID: "Sayornis nigricans_Black Phoebe",
        confirmedAt: Date(timeIntervalSince1970: 1_790_000_000),
        location: Coordinate(latitude: 34.1365, longitude: -118.2942, accuracy: 12),
        soundConfidence: 0.82,
        frameImagePath: "frame.jpg",
        source: .glasses,
        note: "Tail dipping over the pond."
    )

    static func photo(license: String) -> PackPhoto {
        PackPhoto(
            id: "1", speciesID: "sayornis-nigricans", rank: 0, lensFile: "lens/1.jpg", phoneFile: "phone/1.jpg", observer: "A. Birder",
            observerLogin: "abirder", license: license, creditLine: "© A. Birder, some rights reserved (\(license))", shortCredit: "Photo: A. Birder, \(license)",
            sourceURL: URL(string: "https://www.inaturalist.org/observations/1")!, photoURL: URL(string: "https://example.com/1.jpg")!, inatPhotoID: 1, score: 1
        )
    }

    static let english = Locale(identifier: "en_US")

    @Test("the chosen fields go on the card and in the text; the coordinate never does")
    func chosenFields() {
        var choices = SharePolicy.Choices()
        choices.includeNote = true
        let content = SharePolicy.content(for: Self.sighting, commonName: "Black Phoebe", reference: Self.photo(license: "CC BY"), area: "Los Angeles, CA", choices: choices, locale: Self.english)

        #expect(content.commonName == "Black Phoebe")
        #expect(content.dateText == "Sep 21, 2026")
        #expect(content.areaText == "Los Angeles, CA")
        #expect(content.note == "Tail dipping over the pond.")
        #expect(content.picture == .snapshot(framePath: "frame.jpg"))
        #expect(content.attribution == nil, "the birder's own frame needs no credit")
        let text = SharePolicy.text(for: content)
        #expect(text.contains("Black Phoebe (Sayornis nigricans)\nSep 21, 2026, Los Angeles, CA"))
        #expect(text.contains("“Tail dipping over the pond.”"))
        #expect(text.contains("Powered by BirdNET"))
        #expect(!text.contains("34.1") && !text.contains("118.2"), "no coordinate in the text")

        var none = SharePolicy.Choices()
        none.includeDate = false
        none.includeArea = false
        let bare = SharePolicy.content(for: Self.sighting, commonName: "Black Phoebe", reference: nil, area: "Los Angeles, CA", choices: none, locale: Self.english)
        #expect(bare.dateText == nil && bare.areaText == nil && bare.note == nil)
        #expect(SharePolicy.text(for: bare) == "Black Phoebe (Sayornis nigricans)\nHeard with Featherguild. Powered by BirdNET.")
    }

    @Test("a reference photo carries its observer, license and source; one under a license that does not allow sharing is left out")
    func referenceAttribution() {
        var choices = SharePolicy.Choices()
        choices.useSnapshot = false
        let shared = SharePolicy.content(for: Self.sighting, commonName: "Black Phoebe", reference: Self.photo(license: "CC BY-NC"), area: nil, choices: choices, locale: Self.english)
        #expect(shared.picture == .reference(Self.photo(license: "CC BY-NC")))
        #expect(shared.pictureCaption == "Reference photo. Photo: A. Birder, CC BY-NC")
        #expect(shared.attribution == "Photo: © A. Birder, some rights reserved (CC BY-NC), via iNaturalist https://www.inaturalist.org/observations/1")
        #expect(SharePolicy.text(for: shared).hasSuffix("via iNaturalist https://www.inaturalist.org/observations/1"))

        let reserved = SharePolicy.content(for: Self.sighting, commonName: "Black Phoebe", reference: Self.photo(license: "All rights reserved"), area: nil, choices: choices, locale: Self.english)
        #expect(reserved.picture == .none)
        #expect(reserved.attribution == nil)
        #expect(!SharePolicy.mayShare(Self.photo(license: "CC BY-ND")))
        #expect(SharePolicy.mayShare(Self.photo(license: "CC0")))
    }

    // ADR-0001 (issue #50): pack photos are CC0, CC BY or CC BY-SA. A share-alike photo goes on the card with its
    // credit, and its credit links the CC BY-SA deed.
    @Test("a CC BY-SA reference photo is shared with its credit and links the CC BY-SA deed")
    func shareAlikeReference() {
        var choices = SharePolicy.Choices()
        choices.useSnapshot = false
        let photo = Self.photo(license: "CC BY-SA")
        let shared = SharePolicy.content(for: Self.sighting, commonName: "Black Phoebe", reference: photo, area: nil, choices: choices, locale: Self.english)

        #expect(SharePolicy.mayShare(photo))
        #expect(shared.picture == .reference(photo))
        #expect(shared.pictureCaption == "Reference photo. Photo: A. Birder, CC BY-SA")
        #expect(shared.attribution == "Photo: © A. Birder, some rights reserved (CC BY-SA), via iNaturalist https://www.inaturalist.org/observations/1")
        #expect(photo.licenseURL == URL(string: "https://creativecommons.org/licenses/by-sa/4.0/"))
    }
}
