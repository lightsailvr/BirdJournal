import XCTest

/// Issue #193 (of #185): a photo taken from the lens's "Capture a sighting" is on the phone as an unnamed sighting. A real
/// glasses run on Mock Device Kit, the clip standing in for its stream and a drawn frame for its camera
/// (`-autoGlassesCamera`), with the lens driven by the mock's inputs as a wearer would (`-autoLensCapture`): up to the row, a
/// tap, a tap on the viewfinder. Skipped when the clip is not on disk (`scripts/download-clips.sh`).
final class LensCaptureUITests: XCTestCase {
    private static func clip() throws -> String {
        let clip = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "fixtures/clips/birdnet-example-soundscape.wav")
            .path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: clip) else { throw XCTSkip("no example soundscape at \(clip)") }
        return clip
    }

    @MainActor
    func testAPhotoTakenOnTheLensWaitsUnderSeenThisRunAndInTheRunsReview() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-inMemoryAlbum", "YES", "-collectionIntroShown", "YES", "-mockPreviewPort", "\(Int.random(in: 20_000...60_000))",  // the port is the Mac's, and agents test side by side
            "-autoGlassesListening", try Self.clip(), "-autoGlassesCamera", "YES", "-autoLocation", "griffith", "-autoScreen", "glasses-run",
            "-autoLensCapture", "1", "-reduceMotion", "YES",
        ]
        app.launch()

        // While the run is on: under "Seen this run", unnamed, with nothing announced.
        let rows = app.buttons.matching(identifier: "unnamed-row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 150), "no photo from the lens; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertTrue(app.staticTexts["Seen this run"].exists, "screen: \(app.debugDescription.prefix(4000))")
        XCTAssertTrue(rows.firstMatch.label.hasPrefix("Unnamed sighting, Your photo"), rows.firstMatch.label)
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(app.buttons["Stop listening"].exists, "the run is still on")
        XCTAssertFalse(app.buttons["Keep listening"].exists, "a photo is no add: no patch, no page")

        // A bird heard, so the run has a review; then Stop. The review lists the photo too, and says it is kept.
        let heard = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'House Finch'")).firstMatch
        XCTAssertTrue(heard.waitForExistence(timeout: 120), "no bird heard; screen: \(app.debugDescription.prefix(4000))")
        app.buttons["Stop listening"].tap()
        XCTAssertTrue(app.navigationBars["Your run"].waitForExistence(timeout: 30), "no review; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertTrue(app.staticTexts["Photos you haven't named are kept. Name them any time in Collection, under Sightings."].waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(4000))")
        // The run's own page is under the review and lists it as well: the review's row is the one on top, the last.
        XCTAssertEqual(rows.count, 2, "screen: \(app.debugDescription.prefix(4000))")
        XCTAssertLessThan(rows.element(boundBy: 1).frame.minY, app.staticTexts["What you heard"].frame.minY, "above what was heard")
    }
}
