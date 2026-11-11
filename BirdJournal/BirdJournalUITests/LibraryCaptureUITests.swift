import XCTest

/// Issue #192 (of #185): real taps on the capture camera's library button, on a run in Griffith Park that holds still
/// (`-fakeRunBirds`), with a stand-in camera behind "Capture a sighting" (`-fakeCamera`, which also stands a Photos library in,
/// so no test meets the phone's question about adding to Photos). Skipped when the clip is not on disk
/// (`scripts/download-clips.sh`).
final class LibraryCaptureUITests: XCTestCase {
    private static func clip() throws -> String {
        let clip = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "fixtures/clips/birdnet-example-soundscape.wav")
            .path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: clip) else { throw XCTSkip("no example soundscape at \(clip)") }
        return clip
    }

    /// A phone run in Griffith Park that has heard a House Finch, with nothing in the album, and the camera open over it.
    @MainActor
    private func launchCamera(_ extra: [String] = []) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-inMemoryAlbum", "YES", "-collectionIntroShown", "YES", "-fakeRunBirds", "Haemorhous mexicanus_House Finch",
            "-autoPhoneListening", try Self.clip(), "-autoLocation", "griffith", "-autoScreen", "listening",
            "-fakeCamera", "ready", "-reduceMotion", "YES", "-acknowledgmentSeconds", "90",
        ] + extra
        app.launch()
        let capture = app.buttons["capture-sighting"]
        XCTAssertTrue(capture.waitForExistence(timeout: 90), "no Capture a sighting; screen: \(app.debugDescription.prefix(3000))")
        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: capture)
        wait(for: [enabled], timeout: 60)
        capture.tap()
        XCTAssertTrue(app.buttons["capture-shutter"].waitForExistence(timeout: 15), "no camera; screen: \(app.debugDescription.prefix(3000))")
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// A picture from the library, standing in for the picker's (`-fakeLibraryPhoto`): taken on 18 April 2026 in San Diego.
    /// It is named like a capture, and the sheet shows the photo's own date and place, not the run's Griffith Park and today.
    @MainActor
    func testAPhotoChosenFromTheLibraryIsNamedWithItsOwnDateAndPlace() throws {
        let app = try launchCamera(["-fakeLibraryPhoto", "YES"])
        let library = app.buttons["capture-library"]
        XCTAssertTrue(library.waitForExistence(timeout: 10), "no library button; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertEqual(library.label, "Choose from library")
        let shutter = app.buttons["capture-shutter"]
        XCTAssertLessThan(library.frame.maxX, shutter.frame.minX, "left of the shutter")
        XCTAssertEqual(library.frame.midY, shutter.frame.midY, accuracy: 1, "on the shutter's line")
        XCTAssertEqual(shutter.frame.midX, app.windows.firstMatch.frame.midX, accuracy: 1, "the shutter keeps the middle")
        library.tap()

        XCTAssertTrue(app.navigationBars["Name this bird"].waitForExistence(timeout: 15), "no naming; screen: \(app.debugDescription.prefix(3000))")
        let photo = element(app, "name-bird-photo")
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        XCTAssertTrue(photo.label.hasPrefix("Your photo, Apr 18, 2026"), "the photo's date: \(photo.label)")
        XCTAssertTrue(photo.label.contains(", Near "), "the photo's place: \(photo.label)")
        XCTAssertFalse(photo.label.contains("Griffith") || photo.label.contains("Los Angeles") || photo.label.contains("34.13"), "not the run's place: \(photo.label)")
        XCTAssertTrue(app.staticTexts["The sighting takes this photo's own date and place."].exists, "screen: \(app.debugDescription.prefix(3000))")

        // Its patch goes where the photo was taken: not in the run's Los Angeles.
        let field = app.textFields["name-bird-search"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("calypte\n")
        let anna = app.buttons["name-bird-Calypte anna"]
        XCTAssertTrue(anna.waitForExistence(timeout: 30), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(anna.label.hasPrefix("Anna's Hummingbird, "), anna.label)
        XCTAssertFalse(anna.label.contains("Los Angeles"), "placed in the run's set: \(anna.label)")
        anna.tap()
        let add = app.buttons["name-bird-add"]
        XCTAssertEqual(add.label, "Add and sew patch")
        add.tap()

        // An add like any other: the new patch's page, then the run with the bird under Seen this run.
        let keep = app.buttons["Keep listening"]
        XCTAssertTrue(keep.waitForExistence(timeout: 15), "no new patch; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertFalse(app.staticTexts["New patch, Citrus edition"].exists, "Los Angeles's edition, for a photo from San Diego")
        keep.tap()
        let row = app.buttons["seen-row-Calypte anna"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(4000))")
        XCTAssertEqual(row.label, "Anna's Hummingbird, Seen, your photo, New patch")
    }

    /// The real library: the system's picker opens over the camera with no question about the library asked first, and
    /// Cancel there comes back to the camera with nothing taken.
    @MainActor
    func testTheLibraryButtonOpensTheSystemPickerWithoutAskingForTheLibrary() throws {
        let app = try launchCamera()
        let cancel = try openPicker(app)
        XCTAssertTrue(app.navigationBars["Photos"].waitForExistence(timeout: 30), "not the system's picker; screen: \(app.debugDescription.prefix(6000))")
        cancel.tap()
        XCTAssertTrue(app.buttons["capture-shutter"].waitForExistence(timeout: 10), "the camera is still there")
        XCTAssertFalse(app.navigationBars["Name this bird"].exists, "nothing was chosen")
    }

    /// A photo picked in the system's picker, from the pictures a simulator's library comes with: it goes to its naming
    /// with the date the picture itself carries, years back, and not today's; and "Name it later" keeps it on the run like any
    /// capture. Skipped on a simulator whose library is empty.
    @MainActor
    func testAPhotoPickedInTheSystemPickerIsNamedWithItsOwnDate() throws {
        let app = try launchCamera()
        _ = try openPicker(app)
        let picture = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        guard picture.waitForExistence(timeout: 30) else { throw XCTSkip("no photo in this simulator's library to pick") }
        // "Photo, March 30, 2018, 12:14 PM": the library's own word on when it was taken.
        let said = picture.label
        let year = try XCTUnwrap(said.split(whereSeparator: { !$0.isNumber }).first { $0.count == 4 }.map(String.init), "no year in \(said)")
        picture.tap()

        XCTAssertTrue(app.navigationBars["Name this bird"].waitForExistence(timeout: 30), "no naming after the pick; screen: \(app.debugDescription.prefix(4000))")
        let photo = element(app, "name-bird-photo")
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        XCTAssertTrue(photo.label.hasPrefix("Your photo, "), photo.label)
        XCTAssertFalse(photo.label.contains("Today"), "the picture's date was lost on the way: \(photo.label), picked \(said)")
        XCTAssertTrue(photo.label.contains(", \(year)"), "the picture's own year: \(photo.label), picked \(said)")
        let note = element(app, "name-bird-photo-note")
        XCTAssertTrue(note.exists, "the sheet says where the date and place came from; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertTrue(
            note.label == "The sighting takes this photo's own date and place." || note.label == "This photo carries no place, so the sighting takes its date and the place you're at now.",
            "\(note.label), under \(photo.label)"
        )

        app.buttons["name-bird-later"].tap()
        let unnamed = app.buttons["unnamed-row"]
        XCTAssertTrue(unnamed.waitForExistence(timeout: 10), "the chosen photo was not kept; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertTrue(unnamed.label.hasPrefix("Unnamed sighting, Your photo, "), unnamed.label)
    }

    /// Taps the library button and waits for the system's picker to load, which it must with no permission asked. Gives
    /// its Cancel.
    @MainActor
    private func openPicker(_ app: XCUIApplication) throws -> XCUIElement {
        let library = app.buttons["capture-library"]
        XCTAssertTrue(library.waitForExistence(timeout: 10), "no library button; screen: \(app.debugDescription.prefix(3000))")
        library.tap()
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 30), "no picker; screen: \(app.debugDescription.prefix(6000))")
        XCTAssertTrue(app.staticTexts["Loading…"].waitForNonExistence(timeout: 60), "the picker never loaded")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertEqual(springboard.alerts.count, 0, "the picker needs no permission: \(springboard.alerts.firstMatch.label)")
        return cancel
    }
}
