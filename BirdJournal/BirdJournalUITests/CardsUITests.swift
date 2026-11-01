import XCTest

/// Issue #51: every add earns a card. Real taps on a phone run over the example soundscape: the first add of a species
/// shows the Legendary reveal, Back to my collection lands on its Legendary card, a second add of the same species is
/// the quieter acknowledgment, and opening the card never replays the reveal. Skipped when the clip is not on disk
/// (`scripts/download-clips.sh`).
final class CardsUITests: XCTestCase {
    @MainActor
    func testFirstAddRevealsLegendaryAndARepeatIsANewCard() throws {
        let clip = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "fixtures/clips/birdnet-example-soundscape.wav")
        guard FileManager.default.fileExists(atPath: clip.path(percentEncoded: false)) else {
            throw XCTSkip("no example soundscape at \(clip.path(percentEncoded: false))")
        }
        let app = XCUIApplication()
        app.launchArguments = [
            "-inMemoryAlbum", "YES", "-collectionIntroShown", "YES",
            "-autoPhoneListening", clip.path(percentEncoded: false), "-autoLocation", "denied", "-autoScreen", "listening",
        ]
        app.launch()

        // The first species heard, reviewed and added.
        let review = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Review '")).firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 60), "no species to review; screen: \(app.debugDescription.prefix(3000))")
        let name = String(review.label.dropFirst("Review ".count))
        review.tap()
        let add = app.buttons["Add to journal"]
        XCTAssertTrue(add.waitForExistence(timeout: 10), "no Add to journal; screen: \(app.debugDescription.prefix(3000))")
        add.tap()

        let reveal = app.staticTexts["Your first \(name)"]
        XCTAssertTrue(reveal.waitForExistence(timeout: 10), "no Legendary reveal for \(name); screen: \(app.debugDescription.prefix(4000))")
        let back = app.buttons["Back to my collection"]
        XCTAssertTrue(back.exists)
        back.tap()
        XCTAssertFalse(reveal.waitForExistence(timeout: 2), "the reveal closed")

        // The Cards view, with the new card Legendary.
        let legendary = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS 'Legendary, your first'", name)).firstMatch
        XCTAssertTrue(legendary.waitForExistence(timeout: 10), "no Legendary card for \(name); screen: \(app.debugDescription.prefix(4000))")

        // The same species again from the Listen tab: a new card, said quietly, no reveal.
        app.buttons["Listen"].firstMatch.tap()
        let again = app.buttons["Added. Review \(name)"]
        XCTAssertTrue(again.waitForExistence(timeout: 10), "no added row for \(name); screen: \(app.debugDescription.prefix(4000))")
        again.tap()
        let addAnother = app.buttons["Add another sighting"]
        XCTAssertTrue(addAnother.waitForExistence(timeout: 10))
        addAnother.tap()
        XCTAssertTrue(app.staticTexts["A new card for your collection"].waitForExistence(timeout: 5), "no quiet acknowledgment; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertFalse(reveal.exists, "a repeat add is not a reveal")

        // Two cards of the species now; reopening the Legendary one shows the card (issue #52), not the reveal again.
        app.buttons["Journal"].firstMatch.tap()
        let cards = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name))
        XCTAssertTrue(legendary.waitForExistence(timeout: 10))
        XCTAssertEqual(cards.count, 2, "one card per add; screen: \(app.debugDescription.prefix(4000))")
        legendary.tap()
        XCTAssertTrue(app.buttons["card-flip"].waitForExistence(timeout: 10), "the card did not open; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertFalse(reveal.waitForExistence(timeout: 2), "reopening a card never replays the reveal")
        XCTAssertEqual(app.state, .runningForeground)
    }
}
