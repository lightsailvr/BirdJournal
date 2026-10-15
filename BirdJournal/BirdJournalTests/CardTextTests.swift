import Album
import Foundation
import Testing
@testable import BirdJournal

// Issue #52: what a card says on its front and back, and its fallbacks for a missing place, unknown rarity, missing art
// and no original photo. Truthful labels: "Photo attached" only with an original, the reference photo never passed off
// as the birder's.
@Suite("Card text")
@MainActor
struct CardTextTests {
    static let english = Locale(identifier: "en_US")
    static let here = Coordinate(latitude: 34.1365, longitude: -118.2942, accuracy: 15)

    static func sighting(location: Coordinate? = here, frame: String? = nil) -> Sighting {
        Sighting(speciesID: "Haemorhous mexicanus_House Finch", confirmedAt: .now, location: location, soundConfidence: 0.8, frameImagePath: frame, source: .glasses)
    }

    @Test("BirdNET's weeks read as early, mid or late in their month", arguments: [
        (1, "early January"), (2, "mid January"), (3, "mid January"), (4, "late January"), (42, "mid November"), (48, "late December"),
    ])
    func season(week: Int, expected: String) {
        #expect(CardText.season(week: week, locale: Self.english) == expected)
    }

    @Test("the front names the rarity with its season, or says plainly that it is unavailable")
    func rarityLine() {
        let rare = RaritySnapshot(occurrence: 0.2, label: .rare, calibrationVersion: 1, week: 40)
        #expect(CardText.rarityLine(rare, locale: Self.english) == "Rare here in late October")
        #expect(CardText.rarityLine(nil, locale: Self.english) == "Rarity unavailable for this place and season")
    }

    @Test("the back explains where rarity comes from, and why it is missing when it is")
    func rarityExplanation() {
        let common = RaritySnapshot(occurrence: 0.912, label: .common, calibrationVersion: 1, week: 21)
        let explained = CardText.rarityExplanation(common, commonName: "House Finch", hasLocation: true, locale: Self.english)
        #expect(explained.hasPrefix("Common. The BirdNET geomodel rated the chance of a House Finch here in early June at 0.91 on a scale of 0 to 1, read when you added it."))
        #expect(explained.hasSuffix("not whether the card is Legendary."))

        #expect(CardText.rarityExplanation(nil, commonName: "House Finch", hasLocation: false, locale: Self.english)
            == "Rarity unavailable for this place and season. No location was saved with this sighting, and rarity is never guessed.")
        #expect(CardText.rarityExplanation(nil, commonName: "House Finch", hasLocation: true, locale: Self.english)
            == "Rarity unavailable for this place and season. The BirdNET geomodel has no reading for this bird here.")
    }

    @Test("a sighting with no location says the place was not recorded; a known name wins over the coordinate")
    func place() {
        #expect(CardText.place(location: nil, name: nil) == "Place not recorded")
        #expect(CardText.place(location: Self.here, name: nil) == Self.here.formatted)
        #expect(CardText.place(location: Self.here, name: "Los Feliz") == "Los Feliz")
    }

    @Test("the original photo is an attached one, else the glasses photo; none means no Photo attached")
    func originalPhoto() {
        let bare = Self.sighting()
        #expect(CardText.originalPhotoPath(bare) == nil)
        #expect(CardText.evidence(bare) == "No photo attached")

        let glasses = Self.sighting(frame: "frame.jpg")
        #expect(CardText.originalPhotoPath(glasses) == "frame.jpg")
        #expect(CardText.evidence(glasses) == "Photo attached")

        glasses.attachedPhotoPaths = ["mine.jpg"]
        #expect(CardText.originalPhotoPath(glasses) == "mine.jpg", "the birder's own photo comes first")
    }

    @Test("the art says what it is: the glasses photo, a reference photo that is not the bird, or no art yet")
    func provenance() {
        #expect(CardText.Art(sighting: Self.sighting(frame: "frame.jpg"), referenceCredit: "© Ana, CC BY") == .glassesPhoto("frame.jpg"))
        #expect(CardText.Art(sighting: Self.sighting(), referenceCredit: "© Ana, CC BY") == .referencePhoto(credit: "© Ana, CC BY"))
        #expect(CardText.Art(sighting: Self.sighting(), referenceCredit: nil) == .none)

        #expect(CardText.Art.glassesPhoto("frame.jpg").label == "Your glasses photo")
        #expect(CardText.Art.referencePhoto(credit: "x").label == "Reference photo")
        #expect(CardText.Art.none.label == "No art yet")
        #expect(CardText.Art.glassesPhoto("frame.jpg").provenance == "Your glasses photo from this sighting, at the journal's crop. A photo, not a painting.")
        #expect(CardText.Art.referencePhoto(credit: "© Ana, CC BY").provenance == "A reference photo from your bird pack, not your bird. © Ana, CC BY.")
        #expect(CardText.Art.none.provenance == "No art yet: no photo of this sighting, and no pack photo of this bird.")
    }
}
