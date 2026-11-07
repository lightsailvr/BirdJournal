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

        // Collection showing: the recap has to find the birder wherever they were.
        app.tabBars.buttons["Collection"].tap()
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

    /// Stop on the Lock Screen with a bird's review open: closing that sheet leads on to the recap.
    @MainActor
    func testStopUnderACandidatesSheetReachesTheRecapWhenItCloses() throws {
        guard ProcessInfo.processInfo.environment["BIRDJOURNAL_CAPTURE_DIR"] != nil else { throw XCTSkip("no capture folder") }
        let clip = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "fixtures/clips/birdnet-example-soundscape.wav")
            .path(percentEncoded: false)
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-collectionIntroShown", "YES", "-autoPhoneListening", clip, "-autoLocation", "griffith", "-autoScreen", "listening"]
        app.launch()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'new patch waiting'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 120), "no bird heard; screen: \(app.debugDescription.prefix(3000))")
        let close = app.buttons["Close"]
        // The live list re-sorts as birds call, so a tap can land between rows.
        for _ in 0..<5 where !close.exists {
            row.tap()
            _ = close.waitForExistence(timeout: 4)
        }
        XCTAssertTrue(close.exists, "no sheet; screen: \(app.debugDescription.prefix(3000))")

        let lock = NSSelectorFromString("pressLockButton")
        XCUIDevice.shared.perform(lock)
        sleep(2)
        XCUIDevice.shared.perform(lock)
        sleep(3)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let stop = springboard.buttons["Stop listening"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "no Stop on the Lock Screen; screen: \(springboard.debugDescription.prefix(3000))")
        stop.tap()
        sleep(3)
        app.activate()
        if !app.wait(for: .runningForeground, timeout: 3) { springboard.swipeUp() }

        XCTAssertTrue(close.waitForExistence(timeout: 10), "the bird's sheet stays till it's closed; screen: \(app.debugDescription.prefix(3000))")
        close.tap()
        XCTAssertTrue(app.descendants(matching: .any)["run-recap"].waitForExistence(timeout: 15), "no recap after the sheet closed; screen: \(app.debugDescription.prefix(4000))")
    }

    /// The widget added to the Home Screen as a person adds it, and a tap on it. The widget gallery isn't anyone's interface to
    /// promise, so a step it can't find ends the capture rather than failing anything.
    @MainActor
    func testTheWidgetOnTheHomeScreen() throws {
        guard let folder = ProcessInfo.processInfo.environment["BIRDJOURNAL_CAPTURE_DIR"] else { throw XCTSkip("no capture folder") }
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-collectionIntroShown", "YES", "-seedBoard", "YES", "-autoScreen", "listen"]
        app.launch()
        sleep(6)  // The files are written once the app is in front.
        XCUIDevice.shared.press(.home)
        sleep(2)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func step(_ name: String) { print("WIDGET STEP \(name): \(springboard.debugDescription.prefix(2500))") }
        let widget = springboard.icons.matching(NSPredicate(format: "label == 'Featherguild' AND value == 'Widget'")).firstMatch
        if !widget.waitForExistence(timeout: 2) {
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72)).press(forDuration: 1.5)
            sleep(2)
            step("after press")
            let edit = springboard.buttons["Edit"]
            if edit.waitForExistence(timeout: 3) { edit.tap(); sleep(1) }
            let addWidget = springboard.buttons["Add Widget"]
            guard addWidget.waitForExistence(timeout: 5) else { step("no Add Widget"); throw XCTSkip("no Add Widget") }
            addWidget.tap()
            sleep(3)
            step("gallery")
            let search = springboard.searchFields.firstMatch
            guard search.waitForExistence(timeout: 5) else { throw XCTSkip("no search") }
            search.tap()
            search.typeText("Featherguild")
            sleep(2)
            step("searched")
            let result = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Featherguild'")).element(boundBy: 1)
            guard result.waitForExistence(timeout: 5) else { throw XCTSkip("no result") }
            result.tap()
            sleep(3)
            try save("widget-gallery", to: folder)
            step("detail")
            let add = springboard.buttons.matching(NSPredicate(format: "label CONTAINS 'Add Widget'")).firstMatch
            guard add.waitForExistence(timeout: 5) else { throw XCTSkip("no add button") }
            add.tap()
            sleep(2)
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72)).tap()
            sleep(1)
            let done = springboard.buttons["Done"]
            if done.waitForExistence(timeout: 2) { done.tap() }
        }
        sleep(8)
        try save("widget-home", to: folder)
        step("home")
        guard widget.waitForExistence(timeout: 5) else { throw XCTSkip("the widget isn't readable") }
        widget.tap()
        XCTAssertTrue(app.buttons["card-flip"].waitForExistence(timeout: 15), "the widget didn't open its patch; screen: \(app.debugDescription.prefix(3000))")
        try save("widget-opened", to: folder)
    }
}
