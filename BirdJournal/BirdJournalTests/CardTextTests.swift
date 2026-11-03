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
        #expect(explained.hasSuffix("not about your patches."))

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

    static let packArt = (url: URL(filePath: "/packs/us-ca-la/art/haemorhous-mexicanus.avif"), credit: "© Ana, CC BY" as String?)
    static let reference = (url: URL(filePath: "/packs/us-ca-la/phone/1.jpg"), credit: "© Ana, CC BY")

    @Test("the art order: approved photo art, ready scene art unless Use pack art is set, pack art, the reference photo, then none")
    func artOrder() {
        typealias Art = CardText.Art
        var sighting = Self.sighting(frame: "frame.jpg")
        // The glasses photo is evidence, never art (issue #57).
        #expect(Art(sighting: sighting, packArt: Self.packArt, reference: Self.reference) == .packArt(Self.packArt.url, credit: "© Ana, CC BY"))
        #expect(Art(sighting: sighting, packArt: nil, reference: Self.reference) == .referencePhoto(Self.reference.url, credit: "© Ana, CC BY"))
        #expect(Art(sighting: sighting, packArt: nil, reference: nil) == .none)

        sighting.art = CardArt(scene: ArtImage(path: "scene.jpg", state: .ready))
        #expect(Art(sighting: sighting, packArt: Self.packArt, reference: Self.reference) == .sceneArt(path: "scene.jpg"))
        sighting.art.prefersPackArt = true
        #expect(Art(sighting: sighting, packArt: Self.packArt, reference: Self.reference) == .packArt(Self.packArt.url, credit: "© Ana, CC BY"), "Use pack art")
        #expect(Art(sighting: sighting, packArt: nil, reference: Self.reference) == .referencePhoto(Self.reference.url, credit: "© Ana, CC BY"))

        sighting.art = CardArt(scene: ArtImage(path: "scene.jpg", state: .failed))
        #expect(Art(sighting: sighting, packArt: Self.packArt, reference: Self.reference) == .packArt(Self.packArt.url, credit: "© Ana, CC BY"), "failed scene art")

        sighting.art = CardArt(scene: ArtImage(path: "scene.jpg", state: .ready), photo: ArtImage(path: "photo.jpg", state: .preview))
        #expect(Art(sighting: sighting, packArt: Self.packArt, reference: Self.reference) == .sceneArt(path: "scene.jpg"), "photo art waiting for approval")
        sighting.art = CardArt(prefersPackArt: true, scene: ArtImage(path: "scene.jpg", state: .ready), photo: ArtImage(path: "photo.jpg", state: .ready))
        #expect(Art(sighting: sighting, packArt: Self.packArt, reference: Self.reference) == .photoArt(path: "photo.jpg"), "approved photo art wins")
        sighting.art = CardArt(photo: ArtImage(path: nil, state: .ready))
        #expect(Art(sighting: sighting, packArt: Self.packArt, reference: Self.reference) == .packArt(Self.packArt.url, credit: "© Ana, CC BY"), "no file, no photo art")
    }

    @Test("the art says what it is: AI illustrations and AI-embellished photos labelled so, a reference photo that is not the bird, or no art yet")
    func provenance() {
        typealias Art = CardText.Art
        #expect(Art.photoArt(path: "p").label == "AI-embellished from your photo")
        #expect(Art.sceneArt(path: "s").label == "AI illustration")
        #expect(Art.packArt(Self.packArt.url, credit: nil).label == "AI illustration")
        #expect(Art.referencePhoto(Self.reference.url, credit: "x").label == "Reference photo")
        #expect(Art.none.label == "No art yet")

        #expect(Art.photoArt(path: "p").provenance == "Your own photo, AI-embellished by FLUX.3 Image Klein and approved by you. The original is kept as evidence.")
        #expect(Art.sceneArt(path: "s").provenance == "An AI illustration painted by FLUX.3 Image Klein into your glasses photo from this sighting. Not a photo.")
        #expect(Art.packArt(Self.packArt.url, credit: "© Ana, CC BY").provenance == "An AI illustration from your bird pack, painted by FLUX.3 Image Klein from a reference photo (© Ana, CC BY). It shows the species, not your bird.")
        #expect(Art.packArt(Self.packArt.url, credit: nil).provenance == "An AI illustration from your bird pack, painted by FLUX.3 Image Klein from a description of the species. It shows the species, not your bird.")
        #expect(Art.referencePhoto(Self.reference.url, credit: "© Ana, CC BY").provenance == "A reference photo from your bird pack, not your bird. © Ana, CC BY.")
        #expect(Art.none.provenance == "No art yet: no pack art and no pack photo of this bird.")
    }
}
