import XCTest

/// Issue #150, slice 10, with real taps: a run ends on a paper recap whose image can be shared, skipped birds can still be
/// added, and the widget's link opens a patch. Skipped when the clip is not on disk (`scripts/download-clips.sh`). The Live
/// Activity and the widget themselves are checked by hand on a phone.
final class AfterTheRunUITests: XCTestCase {
    private static func clip() throws -> String {
        let clip = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "fixtures/clips/birdnet-example-soundscape.wav")
            .path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: clip) else { throw XCTSkip("no example soundscape at \(clip)") }
        return clip
    }

    @MainActor
    private func recap(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["run-recap"]
    }

    @MainActor
    private func launchRecap(_ extra: [String] = []) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-inMemoryAlbum", "YES", "-collectionIntroShown", "YES",
            "-autoPhoneListening", try Self.clip(), "-autoLocation", "griffith", "-autoScreen", "recap", "-stitchInSeconds", "0",
        ] + extra
        app.launch()
        return app
    }

    @MainActor
    func testARunEndsOnARecapThatCountsWhatItSaysAndBirdsCanStillBeAdded() throws {
        let app = try launchRecap()
        let card = recap(app)
        XCTAssertTrue(card.waitForExistence(timeout: 120), "no recap; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertTrue(card.label.contains("Listened for"), card.label)
        XCTAssertTrue(card.label.contains("0 patches sewn"), card.label)
        XCTAssertFalse(card.label.contains("·"), "no dots for VoiceOver: \(card.label)")
        let share = app.buttons["recap-share"]
        XCTAssertTrue(share.waitForExistence(timeout: 20), "the image isn't ready; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertTrue(share.isHittable, "Share is in reach")

        let rest = app.staticTexts["Only the birds you add are kept. The rest are forgotten when you close this."]
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Review ' AND NOT (label CONTAINS 'unknown')")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no birds to add; screen: \(app.debugDescription.prefix(4000))")
        var scrolls = 0
        while !rest.isHittable, scrolls < 8 {
            app.swipeUp()
            scrolls += 1
        }
        XCTAssertTrue(rest.exists, "it says what becomes of the rest")
        while !row.isHittable, scrolls > 0 {
            app.swipeDown()
            scrolls -= 1
        }

        // A skipped bird added from here sews its patch, and the recap counts it.
        row.tap()
        let add = app.buttons["Add and sew patch"]
        XCTAssertTrue(add.waitForExistence(timeout: 10), "no add; screen: \(app.debugDescription.prefix(4000))")
        add.tap()
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 20), "no way off the reveal; screen: \(app.debugDescription.prefix(4000))")
        if app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'New patch'")).firstMatch.waitForExistence(timeout: 10) { done.tap() }
        let back = app.navigationBars.buttons.firstMatch
        if !card.waitForExistence(timeout: 3), back.exists { back.tap() }
        XCTAssertTrue(card.waitForExistence(timeout: 10), "back to the recap; screen: \(app.debugDescription.prefix(4000))")
        expectation(for: NSPredicate(format: "label CONTAINS '1 patch sewn'"), evaluatedWith: card)
        waitForExpectations(timeout: 10)
    }

    @MainActor
    func testTheCityCanBeLeftOffAndShareOpensTheSystemShare() throws {
        let app = try launchRecap()
        XCTAssertTrue(recap(app).waitForExistence(timeout: 120), "no recap; screen: \(app.debugDescription.prefix(4000))")
        let explanation = app.staticTexts["recap-place-explanation"]
        let city = app.switches["recap-city"]
        XCTAssertTrue(city.waitForExistence(timeout: 10), "a run with a fix can leave its city off; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertEqual(city.value as? String, "1", "the city is on by default")
        city.switches.firstMatch.tap()
        XCTAssertEqual(city.value as? String, "0")
        XCTAssertTrue(explanation.label.contains("No place goes with it"), explanation.label)
        XCTAssertFalse(recap(app).label.contains("Griffith"), recap(app).label)

        let share = app.buttons["recap-share"]
        XCTAssertTrue(share.waitForExistence(timeout: 20), "the image isn't ready; screen: \(app.debugDescription.prefix(4000))")
        share.tap()
        // The system share runs in its own process and shows as a sheet over the app.
        let sheet = app.otherElements["ActivityListView"]
        let copy = app.buttons["Copy"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 15) || copy.waitForExistence(timeout: 5), "no system share; screen: \(app.debugDescription.prefix(4000))")
    }

    @MainActor
    private func launchBoard() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-collectionIntroShown", "YES", "-seedBoard", "YES", "-autoScreen", "listen"]
        app.launch()
        return app
    }

    /// The bundled pack's first bird, in Griffith Park, as `-seedBoard` adds it: its seeds carry the pack's bare label.
    private static let seeded = "birdjournal://patch?species=Buteo%20jamaicensis&set=us-ca-la"

    /// A link to the app as it runs, as a widget's tap arrives: `XCUIApplication.open` would launch it again. The system asks
    /// first when a link doesn't come from a widget.
    @MainActor
    private func openWhileRunning(_ url: URL) {
        XCUIDevice.shared.system.open(url)
        let open = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"]
        if open.waitForExistence(timeout: 5) { open.tap() }
    }

    @MainActor
    func testTheWidgetsLinkOpensThatPatchsPage() {
        let app = launchBoard()
        XCTAssertTrue(app.tabBars.buttons["Listen"].waitForExistence(timeout: 30))
        openWhileRunning(URL(string: Self.seeded)!)
        XCTAssertTrue(app.buttons["card-flip"].waitForExistence(timeout: 15), "the patch didn't open; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertTrue(app.navigationBars.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Los Angeles, '")).firstMatch.exists, "screen: \(app.debugDescription.prefix(4000))")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Red-tailed Hawk'")).firstMatch.exists, "the right bird; screen: \(app.debugDescription.prefix(4000))")
    }

    @MainActor
    func testALinkToAPatchThatsGoneOpensTheCollection() {
        let app = launchBoard()
        XCTAssertTrue(app.tabBars.buttons["Listen"].waitForExistence(timeout: 30))
        openWhileRunning(URL(string: "birdjournal://patch?species=Corvus%20corax_Common%20Raven&set=us-ca-la")!)
        XCTAssertTrue(app.tabBars.buttons["Collection"].waitForExistence(timeout: 10))
        let selected = expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: app.tabBars.buttons["Collection"])
        wait(for: [selected], timeout: 15)
        XCTAssertFalse(app.buttons["card-flip"].exists, "no page for a patch that isn't there")
    }

    @MainActor
    func testTheLinkOpensThePatchFromAColdStartToo() {
        let app = launchBoard()
        XCTAssertTrue(app.tabBars.buttons["Listen"].waitForExistence(timeout: 30))
        app.open(URL(string: Self.seeded)!)
        XCTAssertTrue(app.buttons["card-flip"].waitForExistence(timeout: 30), "the patch didn't open; screen: \(app.debugDescription.prefix(4000))")
    }

    @MainActor
    func testALinkWaitsForAnOpenReviewSoItsBirdsAreNotLost() throws {
        let app = try launchRecap(["-seedBoard", "YES"])
        XCTAssertTrue(recap(app).waitForExistence(timeout: 120), "no recap; screen: \(app.debugDescription.prefix(4000))")
        openWhileRunning(URL(string: Self.seeded)!)
        XCTAssertFalse(app.buttons["card-flip"].waitForExistence(timeout: 3), "the review stays until the birder closes it")
        XCTAssertTrue(recap(app).exists, "screen: \(app.debugDescription.prefix(3000))")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.buttons["card-flip"].waitForExistence(timeout: 15), "then the patch opens; screen: \(app.debugDescription.prefix(4000))")
    }
}
