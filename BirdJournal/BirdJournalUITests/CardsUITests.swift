import XCTest

/// Issues #132, #135 (of #131; before them #51's Legendary card): the first add of a species in a place sews its patch.
/// Real taps on a phone run over the example soundscape, with no location, so every patch is Uncharted: the first add says
/// "Add and sew patch" and shows the new-patch reveal (Keep listening first, issue #117), See it in my collection lands on
/// the patch, seen once; a second add of the same species says "Add another sighting", says the count is 2 with no page and
/// nothing to tap, and leaves one patch, seen twice; opening the patch replays neither. Skipped when the clip is not on
/// disk (`scripts/download-clips.sh`). `SewingUITests` drives the stitch-in itself, on a patch with a painting.
final class CardsUITests: XCTestCase {
    @MainActor
    func testFirstAddSewsAPatchAndARepeatAddsToItsCount() throws {
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
        let add = app.buttons["Add and sew patch"]
        XCTAssertTrue(add.waitForExistence(timeout: 10), "no Add and sew patch; screen: \(app.debugDescription.prefix(3000))")
        add.tap()

        let reveal = app.staticTexts["Your first \(name)"]
        XCTAssertTrue(reveal.waitForExistence(timeout: 10), "no new-patch reveal for \(name); screen: \(app.debugDescription.prefix(4000))")
        XCTAssertTrue(app.staticTexts["New patch · Uncharted"].exists, "no New patch line; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Legendary'")).firstMatch.exists, "no Legendary")
        XCTAssertTrue(app.buttons["Keep listening"].exists, "no Keep listening during a run; screen: \(app.debugDescription.prefix(4000))")
        let back = app.buttons["See it in my collection"]
        XCTAssertTrue(back.exists)
        back.tap()
        XCTAssertFalse(reveal.waitForExistence(timeout: 2), "the reveal closed")

        // The Patches view, with the new patch seen once.
        let once = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS 'seen once'", name)).firstMatch
        XCTAssertTrue(once.waitForExistence(timeout: 10), "no patch of \(name) seen once; screen: \(app.debugDescription.prefix(4000))")

        // The same species again from the Listen tab: seen again, said quietly, no reveal.
        app.buttons["Listen"].firstMatch.tap()
        let again = app.buttons["Added. Review \(name)"]
        XCTAssertTrue(again.waitForExistence(timeout: 10), "no added row for \(name); screen: \(app.debugDescription.prefix(4000))")
        again.tap()
        let addAnother = app.buttons["Add another sighting"]
        XCTAssertTrue(addAnother.waitForExistence(timeout: 10))
        addAnother.tap()
        XCTAssertTrue(app.staticTexts["Seen again · 2 times"].waitForExistence(timeout: 5), "no seen-again acknowledgment; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertFalse(reveal.exists, "a repeat add is not a reveal")
        XCTAssertFalse(app.buttons["stitch-in"].exists, "a repeat add stitches nothing")
        XCTAssertFalse(app.buttons["Keep listening"].exists, "and opens no page")

        // Still one patch of the species, seen twice; reopening it shows its page (issue #134), not the reveal again.
        app.tabBars.buttons["Collection"].tap()
        let twice = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS 'seen 2 times'", name)).firstMatch
        XCTAssertTrue(twice.waitForExistence(timeout: 10), "no patch of \(name) seen twice; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).count, 1, "one patch, not one per add; screen: \(app.debugDescription.prefix(4000))")
        twice.tap()
        XCTAssertTrue(app.buttons["card-flip"].waitForExistence(timeout: 10), "the patch did not open; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertFalse(reveal.waitForExistence(timeout: 2), "reopening a patch never replays the reveal")
        XCTAssertEqual(app.state, .runningForeground)
    }
}
