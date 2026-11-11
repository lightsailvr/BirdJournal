import XCTest

/// Issue #187 (of #185): real touches on the capture camera's controls. The simulator has no camera, so the stand-in is behind
/// the screen (`-fakeCamera ready`, an iPhone 17 Pro's lenses), and what it reports of its zoom and its focus is what the
/// viewfinder says. Skipped when the clip is not on disk (`scripts/download-clips.sh`).
final class CameraControlsUITests: XCTestCase {
    private static func clip() throws -> String {
        let clip = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "fixtures/clips/birdnet-example-soundscape.wav")
            .path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: clip) else { throw XCTSkip("no example soundscape at \(clip)") }
        return clip
    }

    /// A phone run with the camera open over it, ready.
    @MainActor
    private func launchCamera() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-inMemoryAlbum", "YES", "-collectionIntroShown", "YES", "-fakeRunBirds", "Haemorhous mexicanus_House Finch",
            "-autoPhoneListening", try Self.clip(), "-autoLocation", "griffith", "-autoScreen", "capture",
            "-fakeCamera", "ready", "-reduceMotion", "YES",
        ]
        app.launch()
        let shutter = app.buttons["capture-shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 90), "no camera; screen: \(app.debugDescription.prefix(3000))")
        let ready = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: shutter)
        wait(for: [ready], timeout: 30)
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// What the viewfinder says of the camera's zoom, once it says `expected` (or, with nil, whatever it says now).
    @MainActor
    private func viewfinderValue(_ app: XCUIApplication, becomes expected: String? = nil) -> String {
        let viewfinder = element(app, "capture-viewfinder")
        if let expected {
            let said = expectation(for: NSPredicate(format: "value == %@", expected), evaluatedWith: viewfinder)
            _ = XCTWaiter().wait(for: [said], timeout: 5)
        }
        return viewfinder.value as? String ?? ""
    }

    private func factor(_ value: String) throws -> Double {
        try XCTUnwrap(Double(value.replacingOccurrences(of: " times zoom", with: "")), "not a zoom: \(value)")
    }

    @MainActor
    func testTheLensButtonsAreThePhonesAndATapOnOneZoomsThereAndMarksIt() throws {
        let app = try launchCamera()
        let lenses = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "capture-lens-"))
        XCTAssertEqual(lenses.allElementsBoundByIndex.map(\.identifier), ["capture-lens-0.5", "capture-lens-1", "capture-lens-2", "capture-lens-4", "capture-lens-8"], "an iPhone 17 Pro's steps, left to right")
        XCTAssertEqual(lenses.allElementsBoundByIndex.map(\.label), ["0.5 times zoom", "1 times zoom", "2 times zoom", "4 times zoom", "8 times zoom"])
        XCTAssertEqual(lenses.allElementsBoundByIndex.filter(\.isSelected).map(\.identifier), ["capture-lens-1"], "it opens on the wide lens")
        XCTAssertEqual(viewfinderValue(app), "1 times zoom")

        // The flash is off, and there is nothing to press to change that.
        let flash = element(app, "capture-flash-off")
        XCTAssertTrue(flash.exists, "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertEqual(flash.label, "Flash off")
        XCTAssertNotEqual(flash.elementType, .button)

        // One hand: every lens button takes a thumb, low on the screen, just above the shutter.
        let screen = app.windows.firstMatch.frame
        let shutter = app.buttons["capture-shutter"]
        let viewfinder = element(app, "capture-viewfinder")
        for lens in lenses.allElementsBoundByIndex {
            XCTAssertGreaterThan(lens.frame.width, 43.9, lens.identifier)
            XCTAssertGreaterThan(lens.frame.height, 43.9, lens.identifier)
            XCTAssertTrue(lens.isHittable, lens.identifier)
            XCTAssertGreaterThan(lens.frame.minY, screen.height * 0.6, "\(lens.identifier) is in the lower part of the screen")
            XCTAssertLessThan(lens.frame.maxY, shutter.frame.minY, "\(lens.identifier) is above the shutter")
            XCTAssertTrue(viewfinder.frame.contains(lens.frame), "\(lens.identifier) is on the viewfinder's bottom edge")
        }

        // The telephoto: the stand-in camera reports 4, and its button is the marked one.
        app.buttons["capture-lens-4"].tap()
        XCTAssertEqual(viewfinderValue(app, becomes: "4 times zoom"), "4 times zoom")
        XCTAssertEqual(lenses.allElementsBoundByIndex.filter(\.isSelected).map(\.identifier), ["capture-lens-4"])
        app.buttons["capture-lens-0.5"].tap()
        XCTAssertEqual(viewfinderValue(app, becomes: "0.5 times zoom"), "0.5 times zoom")
        XCTAssertEqual(lenses.allElementsBoundByIndex.filter(\.isSelected).map(\.identifier), ["capture-lens-0.5"])

        // Zoomed all the way to the last lens, what is around the viewfinder still takes its taps.
        app.buttons["capture-lens-8"].tap()
        XCTAssertEqual(viewfinderValue(app, becomes: "8 times zoom"), "8 times zoom")
        app.buttons["Close camera"].tap()
        XCTAssertTrue(app.buttons["capture-sighting"].waitForExistence(timeout: 10), "back on the run; screen: \(app.debugDescription.prefix(3000))")
    }

    @MainActor
    func testAPinchZoomsBetweenTheLensesAndTheMarkedButtonReadsTheFactor() throws {
        let app = try launchCamera()
        let viewfinder = element(app, "capture-viewfinder")
        let lenses = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "capture-lens-"))
        XCTAssertEqual(viewfinderValue(app), "1 times zoom")

        viewfinder.pinch(withScale: 3, velocity: 3)
        let zoomedIn = try factor(viewfinderValue(app))
        XCTAssertGreaterThan(zoomedIn, 1.5, "the pinch zoomed in")
        XCTAssertLessThanOrEqual(zoomedIn, 40)
        // The factor is on the lens it has passed, which is the marked one.
        let marked = lenses.allElementsBoundByIndex.filter(\.isSelected)
        XCTAssertEqual(marked.count, 1)
        XCTAssertEqual(marked.first?.label, viewfinderValue(app))
        XCTAssertEqual(lenses.count, 5, "and no button came or went")

        viewfinder.pinch(withScale: 0.2, velocity: -3)
        let zoomedOut = try factor(viewfinderValue(app))
        XCTAssertLessThan(zoomedOut, zoomedIn, "and back out, from where it was")
        XCTAssertGreaterThanOrEqual(zoomedOut, 0.5, "no wider than the widest lens")

        // A lens button from in between: on the step, exactly.
        app.buttons["capture-lens-2"].tap()
        XCTAssertEqual(viewfinderValue(app, becomes: "2 times zoom"), "2 times zoom")
    }

    @MainActor
    func testATapOnTheViewfinderShowsWhereFocusIsHeldAndTheShutterStillTakesThePhoto() throws {
        let app = try launchCamera()
        let viewfinder = element(app, "capture-viewfinder")
        let square = element(app, "capture-focus-square")
        XCTAssertFalse(square.exists, "the camera focuses by itself until told where")

        let spot = viewfinder.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.35))
        spot.tap()
        XCTAssertEqual(viewfinderValue(app, becomes: "1 times zoom, focus set"), "1 times zoom, focus set")
        XCTAssertTrue(square.waitForExistence(timeout: 5), "no square where the tap landed; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertEqual(square.frame.midX, spot.screenPoint.x, accuracy: 2)
        XCTAssertEqual(square.frame.midY, spot.screenPoint.y, accuracy: 2)

        // Another tap moves it.
        let other = viewfinder.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.2))
        other.tap()
        let deadline = Date().addingTimeInterval(5)
        while abs(square.frame.midX - other.screenPoint.x) > 2, Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertEqual(square.frame.midX, other.screenPoint.x, accuracy: 2)
        XCTAssertEqual(square.frame.midY, other.screenPoint.y, accuracy: 2)

        // A lens button sits on the viewfinder: pressing it zooms, and is not a tap on the picture under it.
        app.buttons["capture-lens-2"].tap()
        XCTAssertEqual(viewfinderValue(app, becomes: "2 times zoom, focus set"), "2 times zoom, focus set")
        XCTAssertEqual(square.frame.midX, other.screenPoint.x, accuracy: 2)

        app.buttons["capture-shutter"].tap()
        XCTAssertTrue(app.navigationBars["Name this bird"].waitForExistence(timeout: 15), "no naming; screen: \(app.debugDescription.prefix(3000))")
    }

    /// On its side the screen leaves the viewfinder narrower than the row of buttons: the ones that reach past its edges
    /// must still take a thumb.
    @MainActor
    func testWithThePhoneOnItsSideEveryLensButtonStillTakesItsTap() throws {
        let app = try launchCamera()
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        let shutter = app.buttons["capture-shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 10))
        let screen = app.windows.firstMatch.frame
        XCTAssertGreaterThan(screen.width, screen.height, "the screen turned")

        for step in ["0.5", "8", "1", "4", "2"] {
            let lens = app.buttons["capture-lens-\(step)"]
            XCTAssertTrue(lens.isHittable, "\(step); screen: \(app.debugDescription.prefix(3000))")
            XCTAssertGreaterThan(lens.frame.width, 43.9, step)
            XCTAssertFalse(lens.frame.intersects(shutter.frame), "\(step) is clear of the shutter")
            lens.tap()
            XCTAssertEqual(viewfinderValue(app, becomes: "\(step) times zoom"), "\(step) times zoom")
        }
        XCTAssertTrue(shutter.isHittable)
        XCUIDevice.shared.orientation = .portrait
    }
}
