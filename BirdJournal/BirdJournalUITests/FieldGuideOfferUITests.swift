import CryptoKit
import XCTest

/// A field guide offered where the birder is (issue #223, of #206), with real launches. The phone is a fresh install whose
/// index is a file this test writes: it lists the pack fixtures' made-up set, Test Pack, around `-autoLocation testland`, as a
/// 173 MB download served from the fixture zip, and San Diego, which the phone knows from what shipped with the app, as a
/// download that is never started. So the offer's button downloads and installs a real field guide with no network.
final class FieldGuideOfferUITests: XCTestCase {
    private static let offerTitle = "You're in the Test Pack set"
    private static let notOnPhone = "This set's field guide isn't on your iPhone yet, so birds you find here aren't sewn into this set."

    /// Writes the index beside nothing else, and gives its URL.
    private static func index() throws -> URL {
        let zip = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "BirdJournalKit/Tests/PackTests/Fixtures/test-pack.zip")
        let sha256 = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
        // The set as the fixture pack carries it (`packbuilder/tests/make_fixture_pack.py`): a square degree of sea off West Africa.
        let set: [String: Any] = [
            "id": "test-pack", "name": "Test Pack", "edition": ["name": "Test edition", "theme": "a test card's light"], "taxonomy": "IOC World Bird List 15.1",
            "regions": [["name": "Testland", "source": "hand-drawn polygon", "polygons": [[[[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0], [0.0, 0.0]]]]]],
            "species": [["scientificName": "Calypte anna", "commonName": "Anna's Hummingbird"], ["scientificName": "Sayornis nigricans", "commonName": "Black Phoebe"]],
        ]
        let packs: [[String: Any]] = [
            ["id": "test-pack", "name": "Test Pack", "version": 1, "url": zip.absoluteString, "sha256": sha256, "byteCount": 173_000_000, "speciesCount": 2, "schemaVersion": 4, "set": set],
            ["id": "us-ca-sd", "name": "San Diego", "version": 1, "url": "http://127.0.0.1:9/us-ca-sd.zip", "sha256": "00", "byteCount": 181_000_000, "schemaVersion": 4],
        ]
        let folder = FileManager.default.temporaryDirectory.appending(path: "FieldGuideOfferUITests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "index.json")
        try JSONSerialization.data(withJSONObject: ["packs": packs]).write(to: url)
        return url
    }

    /// - Parameter fresh: forget what earlier launches dismissed, as a new install has.
    @MainActor
    private func launch(at place: String, index: URL, fresh: Bool, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-inMemoryAlbum", "YES", "-collectionIntroShown", "YES", "-freshPackStorage", "YES", "-packIndexURL", index.absoluteString,
            "-autoLocation", place, "-reduceMotion", "YES",
        ] + (fresh ? ["-resetFieldGuideOffers", "YES"] : []) + extra
        app.launch()
        return app
    }

    /// Scrolls Listen until `element` is clear of the tab bar that floats over the page's foot.
    @MainActor
    private func bringUp(_ element: XCUIElement, in app: XCUIApplication) {
        let inReach = app.windows.firstMatch.frame.insetBy(dx: 0, dy: 140)
        for _ in 0..<4 where element.exists && !inReach.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) {
            app.swipeUp()
        }
    }

    @MainActor
    func testTheOfferNamesTheSetAndItsSizeAndItsButtonDownloadsTheFieldGuide() throws {
        let app = launch(at: "testland", index: try Self.index(), fresh: true)
        XCTAssertTrue(app.buttons["Your local set, Test Pack"].waitForExistence(timeout: 30), "the place; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.staticTexts[Self.offerTitle].waitForExistence(timeout: 10), "no offer; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "field-guide download brings the Test edition")).firstMatch.exists, "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertFalse(app.staticTexts[Self.notOnPhone].exists, "the offer says it instead")
        let download = app.buttons["pack-download-test-pack"]
        XCTAssertEqual(download.label, "Download, 173 MB")
        XCTAssertTrue(app.buttons["Not now"].exists)

        bringUp(download, in: app)
        download.tap()

        // The fixture zip is small, so the field guide is on the phone in a moment: the set takes sightings, and there's nothing left to offer.
        XCTAssertTrue(app.staticTexts["Birds you add are sewn as patches here, one for every bird in every place."].waitForExistence(timeout: 30), "not downloaded; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertFalse(app.staticTexts[Self.offerTitle].exists, "still offered with the field guide on the phone")
        XCTAssertFalse(app.buttons["Not now"].exists)
    }

    @MainActor
    func testTheOfferIsOnTheSetsPageAndADismissalIsRememberedForThatSetOnly() throws {
        let index = try Self.index()
        var app = launch(at: "testland", index: index, fresh: true)
        let local = app.buttons["Your local set, Test Pack"]
        XCTAssertTrue(local.waitForExistence(timeout: 30), "the place; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.staticTexts[Self.offerTitle].waitForExistence(timeout: 10), "no offer on Listen; screen: \(app.debugDescription.prefix(3000))")

        // The set's own page has the offer in place of its ordinary Download, not beside it.
        bringUp(local, in: app)
        local.tap()
        XCTAssertTrue(app.navigationBars["Test Pack"].waitForExistence(timeout: 10), "the set's page; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.staticTexts[Self.offerTitle].waitForExistence(timeout: 10), "no offer on the set's page; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertEqual(app.buttons.matching(identifier: "pack-download-test-pack").count, 1, "one Download")
        XCTAssertEqual(app.buttons["pack-download-test-pack"].label, "Download, 173 MB")

        app.buttons["Not now"].tap()

        // Dismissed: the ordinary Download and its words are what's left.
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.staticTexts[Self.offerTitle])
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 10), .completed, "still offered; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertEqual(app.buttons["pack-download-test-pack"].label, "Download, 173 MB", "the set's page keeps its Download")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Download it and they become its patches")).firstMatch.exists, "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertFalse(app.buttons["Not now"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts[Self.notOnPhone].waitForExistence(timeout: 10), "Listen says so plainly; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertFalse(app.staticTexts[Self.offerTitle].exists)
        app.terminate()

        // The next launch remembers.
        app = launch(at: "testland", index: index, fresh: false)
        XCTAssertTrue(app.buttons["Your local set, Test Pack"].waitForExistence(timeout: 30), "the place; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.staticTexts[Self.notOnPhone].waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertFalse(app.staticTexts[Self.offerTitle].exists, "offered again after a dismissal")
        XCTAssertFalse(app.buttons["Not now"].exists)
        app.terminate()

        // Another set's offer is its own.
        app = launch(at: "san-diego", index: index, fresh: false)
        XCTAssertTrue(app.buttons["Your local set, San Diego"].waitForExistence(timeout: 30), "the place; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.staticTexts["You're in the San Diego set"].waitForExistence(timeout: 10), "no offer for another set; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertEqual(app.buttons["pack-download-us-ca-sd"].label, "Download, 181 MB")
    }

    /// Kansas is in no regional set, and what it falls back to has its field guide on the phone.
    @MainActor
    func testNothingIsOfferedOutsideEveryRegionalSet() throws {
        let app = launch(at: "kansas", index: try Self.index(), fresh: true, ["-autoScreen", "guide"])
        // The index has been read: the Atlas lists the set it describes.
        let tile = app.buttons["guide-set-test-pack"]
        for _ in 0..<8 where !tile.waitForExistence(timeout: 3) { app.swipeUp() }
        XCTAssertTrue(tile.exists, "the index never came; screen: \(app.debugDescription.prefix(3000))")
        app.tabBars.buttons["Listen"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Your local set, ")).firstMatch.waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertFalse(app.otherElements["field-guide-offer"].exists, "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertFalse(app.buttons["Not now"].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Download'")).firstMatch.exists)
    }
}
