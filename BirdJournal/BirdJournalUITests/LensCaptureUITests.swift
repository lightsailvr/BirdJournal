import XCTest

/// Issue #193 (of #185): a photo taken from the lens's "Capture a sighting" is on the phone as an unnamed sighting. A real
/// glasses run on Mock Device Kit, the clip standing in for its stream and a drawn frame for its camera
/// (`-autoGlassesCamera`), with the lens driven by the mock's inputs as a wearer would (`-autoLensCapture`): up to the row and a
/// tap on it, which is the shutter. Skipped when the clip is not on disk (`scripts/download-clips.sh`).
final class LensCaptureUITests: XCTestCase {
    private static func clip() throws -> String {
        let clip = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "fixtures/clips/birdnet-example-soundscape.wav")
            .path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: clip) else { throw XCTSkip("no example soundscape at \(clip)") }
        return clip
    }

    /// Issue #194: after the photo the lens asks for the bird's name, and the mock's glasses hear "annas humming bird"
    /// (`-autoLensSay`), as a recogniser would write it. The first bird offered is tapped.
    @MainActor
    func testABirdNamedByVoiceOnTheLensIsSeenThisRunAndItsPatchIsSewnOnceTheRunEnds() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-inMemoryAlbum", "YES", "-collectionIntroShown", "YES", "-mockPreviewPort", "\(Int.random(in: 20_000...60_000))",
            "-autoGlassesListening", try Self.clip(), "-autoGlassesCamera", "YES", "-autoLocation", "griffith", "-autoScreen", "glasses-run",
            "-autoLensCapture", "1", "-lensAsksName", "YES", "-autoLensSay", "annas humming bird", "-stitchInSeconds", "60",
        ]
        app.launch()

        // While the run is on: the photo is the hummingbird's sighting under "Seen this run", and nothing else happens on
        // the phone, as for an add on the lens.
        let row = app.buttons["seen-row-Calypte anna"]
        XCTAssertTrue(row.waitForExistence(timeout: 150), "the lens named no photo; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertEqual(row.label, "Anna's Hummingbird, Seen, your photo, New patch")
        XCTAssertFalse(app.buttons["unnamed-row"].exists, "the photo has its name")
        XCTAssertFalse(app.buttons["dictation-allow"].exists)
        let stitching = app.buttons["stitch-in"]
        XCTAssertFalse(stitching.waitForExistence(timeout: 4), "nothing on the phone mid-run; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertFalse(app.buttons["Keep listening"].exists, "nothing on the phone mid-run")

        // The run ends: the patch's stitch-in, held for now, plays.
        app.buttons["Stop listening"].tap()
        XCTAssertTrue(stitching.waitForExistence(timeout: 15), "no stitch-in when the run ended; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertEqual(stitching.label, "Sewing your Anna's Hummingbird patch")
    }

    /// Issue #194: without the glasses' microphone permission the lens cannot ask for a name. The photo waits unnamed, and
    /// the run's page explains dictation and offers the hop to Meta AI.
    @MainActor
    func testWithoutTheGlassesMicrophoneThePhotoWaitsUnnamedAndThePhoneOffersDictation() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-inMemoryAlbum", "YES", "-collectionIntroShown", "YES", "-mockPreviewPort", "\(Int.random(in: 20_000...60_000))",
            "-autoGlassesListening", try Self.clip(), "-autoGlassesCamera", "YES", "-autoLocation", "griffith", "-autoScreen", "glasses-run",
            "-autoGlassesMicrophone", "denied", "-autoLensCapture", "1", "-lensAsksName", "YES", "-autoLensSay", "annas humming bird", "-reduceMotion", "YES",
        ]
        app.launch()

        XCTAssertTrue(app.buttons["unnamed-row"].waitForExistence(timeout: 150), "no photo from the lens; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertFalse(app.buttons["seen-row-Calypte anna"].exists, "nothing was heard: the lens never listened")
        XCTAssertTrue(app.staticTexts["Say the bird's name on your glasses"].waitForExistence(timeout: 10), "no offer; screen: \(app.debugDescription.prefix(4000))")
        let allow = app.buttons["dictation-allow"]
        XCTAssertTrue(allow.exists, "screen: \(app.debugDescription.prefix(4000))")
        XCTAssertEqual(allow.label, "Allow in Meta AI")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'in the Meta AI app, which opens next'")).firstMatch.exists, "the explanation comes before the hop")
        XCTAssertTrue(app.buttons["Stop listening"].exists, "the run is still on")
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
