import XCTest

/// The profile's reference sounds (issue #41): a real tap plays the song, the row turns into its stop control, the
/// clip plays to its end, and a tap on the playing call stops it.
final class GuideUITests: XCTestCase {
    @MainActor
    func testSongAndCallPlayFromTheProfile() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-autoScreen", "profile"]
        app.launch()

        let song = app.buttons["sound-song"]
        XCTAssertTrue(song.waitForExistence(timeout: 15), "no song row; screen: \(app.debugDescription.prefix(3000))")
        for _ in 0..<3 where !song.isHittable { app.swipeUp() }
        XCTAssertEqual(song.label, "Play the song")
        XCTAssertTrue(song.value as? String ?? "" != "", "no credit beside the control")

        song.tap()
        XCTAssertTrue(song.waitForLabel("Stop the song", timeout: 5), "the song did not start; label \(song.label)")
        XCTAssertTrue(song.waitForLabel("Play the song", timeout: 15), "the 8 s clip did not end on its own")

        let call = app.buttons["sound-call"]
        XCTAssertTrue(call.exists)
        call.tap()
        XCTAssertTrue(call.waitForLabel("Stop the call", timeout: 5), "the call did not start; label \(call.label)")
        call.tap()
        XCTAssertTrue(call.waitForLabel("Play the call", timeout: 5), "a tap on the playing call did not stop it")
        XCTAssertEqual(app.state, .runningForeground)
    }
}

extension XCUIElement {
    /// Waits for the element's accessibility label to read `label`.
    func waitForLabel(_ label: String, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
