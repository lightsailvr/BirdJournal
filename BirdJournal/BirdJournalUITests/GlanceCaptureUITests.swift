import XCTest

/// The real Live Activity on the simulator (issue #150): the Dynamic Island and the Lock Screen, which no launch flag can
/// reach, and Stop on the Lock Screen. For the slice's screenshots rather than the suite: it needs the system's own UI, which
/// changes between releases, so it runs only when given somewhere to put them:
///
///     TEST_RUNNER_BIRDJOURNAL_CAPTURE_DIR=<folder> scripts/build-and-test.sh -only-testing:BirdJournalUITests/GlanceCaptureUITests
final class GlanceCaptureUITests: XCTestCase {
    private func save(_ name: String, to folder: String) throws {
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appending(path: "\(name).png"))
    }

    @MainActor
    func testTheRunOutsideTheApp() throws {
        guard let folder = ProcessInfo.processInfo.environment["BIRDJOURNAL_CAPTURE_DIR"] else { throw XCTSkip("no capture folder") }
        let clip = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "fixtures/clips/birdnet-example-soundscape.wav")
            .path(percentEncoded: false)
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-collectionIntroShown", "YES", "-autoPhoneListening", clip, "-autoLocation", "griffith", "-autoScreen", "listening"]
        app.launch()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Review '")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 120), "no bird heard; screen: \(app.debugDescription.prefix(3000))")

        XCUIDevice.shared.press(.home)
        sleep(3)
        try save("activity-island-compact", to: folder)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // Touch and hold the Island to open it.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.03)).press(forDuration: 1)
        sleep(2)
        try save("activity-island-expanded", to: folder)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).tap()
        sleep(1)

        let lock = NSSelectorFromString("pressLockButton")
        XCUIDevice.shared.perform(lock)
        sleep(2)
        XCUIDevice.shared.perform(lock)
        sleep(3)
        try save("activity-lock-screen", to: folder)
        print("LOCK SCREEN TREE: \(springboard.debugDescription.prefix(6000))")

        // Stop on the Lock Screen ends the run, and the recap is waiting back in the app.
        let stop = springboard.buttons["Stop listening"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "no Stop on the Lock Screen; screen: \(springboard.debugDescription.prefix(4000))")
        stop.tap()
        sleep(3)
        XCTAssertFalse(stop.exists, "the activity should end with the run")
        try save("activity-lock-screen-after-stop", to: folder)
        app.activate()
        sleep(2)
        if !app.wait(for: .runningForeground, timeout: 3) { springboard.swipeUp() }
        XCTAssertTrue(app.descendants(matching: .any)["run-recap"].waitForExistence(timeout: 20), "no recap after Stop on the Lock Screen; screen: \(app.debugDescription.prefix(4000))")
        try save("activity-recap-after-lock-stop", to: folder)
    }
}
