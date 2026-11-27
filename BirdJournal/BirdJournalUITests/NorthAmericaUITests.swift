import CryptoKit
import XCTest

/// Issue #215 (of #206): real taps with the North America pack on the phone as a download beside the bundled Los Angeles
/// pack. A bird found in Chicago sews a Continental patch, with its stitch-in, its collector number and "in North America";
/// the same bird found in Griffith Park, which both sets list, still sews its Citrus patch.
///
/// The pack is a stand-in (`north-america-stand-in.zip` among the Pack tests' fixtures: the committed set with two of its
/// birds and drawn patches), listed in an index this test writes and downloaded through the app's own download path into a
/// fresh pack storage, so nothing is left on the simulator. The pack's own paintings wait for the maintainer's review.
final class NorthAmericaUITests: XCTestCase {
    private static let robin = "American Robin"

    /// An index that lists the stand-in pack by its zip on this Mac's disk, in the runner's temporary folder.
    private static func index() throws -> URL {
        let zip = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "BirdJournalKit/Tests/PackTests/Fixtures/north-america-stand-in.zip")
        let data = try Data(contentsOf: zip)
        let pack: [String: Any] = [
            "id": "north-america", "name": "North America", "version": 1, "url": zip.absoluteString,
            "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), "byteCount": data.count,
            "speciesCount": 2, "photoCount": 6, "region": "United States and Canada", "soundCount": 0, "schemaVersion": 5,
        ]
        let file = FileManager.default.temporaryDirectory.appending(path: "north-america-index-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: ["packs": [pack]]).write(to: file)
        return file
    }

    /// Launches on the packs screen with the stand-in downloading, waits until it is on the phone, and goes to the idle
    /// Listen tab at `location`. The stitch-in is slow enough to catch.
    @MainActor
    private func launchWithNorthAmericaDownloaded(location: String) throws -> XCUIApplication {
        let index = try Self.index()
        addTeardownBlock { try? FileManager.default.removeItem(at: index) }
        let app = XCUIApplication()
        app.launchArguments = [
            "-inMemoryAlbum", "YES", "-collectionIntroShown", "YES", "-autoLocation", location, "-fakeCamera", "ready",
            "-stitchInSeconds", "60", "-acknowledgmentSeconds", "90",
            "-freshPackStorage", "YES", "-packIndexURL", index.absoluteString, "-autoDownloadPack", "north-america",
        ]
        app.launch()
        let downloaded = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'North America' AND label CONTAINS '2 birds'")).firstMatch
        XCTAssertTrue(downloaded.waitForExistence(timeout: 90), "the stand-in pack never arrived; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertTrue(downloaded.label.contains("Continental edition"), downloaded.label)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Los Angeles' AND label CONTAINS 'included with the app'")).firstMatch.exists, "beside the bundled pack; screen: \(app.debugDescription.prefix(4000))")
        app.tabBars.buttons["Listen"].tap()
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, labelled label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// "Capture a sighting" on the idle tab, the stand-in camera's photo, then the robin by name: its row is returned,
    /// chosen, with the add in reach.
    @MainActor
    private func captureAndFindTheRobin(_ app: XCUIApplication) -> XCUIElement {
        let capture = app.buttons["capture-sighting"]
        XCTAssertTrue(capture.waitForExistence(timeout: 60), "no Capture a sighting; screen: \(app.debugDescription.prefix(3000))")
        capture.tap()
        let shutter = app.buttons["capture-shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 15), "no camera; screen: \(app.debugDescription.prefix(3000))")
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: shutter)], timeout: 15)
        shutter.tap()
        XCTAssertTrue(app.navigationBars["Name this bird"].waitForExistence(timeout: 15), "no naming; screen: \(app.debugDescription.prefix(3000))")
        let field = app.textFields["name-bird-search"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no search field; screen: \(app.debugDescription.prefix(3000))")
        field.tap()
        field.typeText("turdus migratorius\n")
        let row = app.buttons["name-bird-Turdus migratorius"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "screen: \(app.debugDescription.prefix(3000))")
        return row
    }

    /// Chooses the row, adds, and taps through the stitch-in to the new patch's page.
    @MainActor
    private func addAndSew(_ app: XCUIApplication, _ row: XCUIElement) {
        row.tap()
        let add = app.buttons["name-bird-add"]
        XCTAssertEqual(add.label, "Add and sew patch")
        add.tap()
        let stitching = app.buttons["stitch-in"]
        XCTAssertTrue(stitching.waitForExistence(timeout: 15), "no stitch-in; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertEqual(stitching.label, "Sewing your \(Self.robin) patch")
        stitching.tap()
        XCTAssertTrue(app.buttons["Share this patch"].waitForExistence(timeout: 15), "no new patch's page; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertFalse(stitching.exists, "the stitch-in is over")
    }

    @MainActor
    func testABirdFoundInChicagoSewsAContinentalPatchWithItsCeremonyNumberAndWords() throws {
        let app = try launchWithNorthAmericaDownloaded(location: "chicago")
        let row = captureAndFindTheRobin(app)
        XCTAssertEqual(row.label, "\(Self.robin), North America, New to you here")
        addAndSew(app, row)

        // The new patch's page: the edition and the set it is the first of.
        XCTAssertTrue(app.staticTexts["New patch, Continental edition"].exists, "screen: \(app.debugDescription.prefix(4000))")
        XCTAssertTrue(app.staticTexts["Your first \(Self.robin) in North America"].exists, "screen: \(app.debugDescription.prefix(4000))")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["New patch, Continental edition"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Your first \(Self.robin) in North America"].waitForExistence(timeout: 10), "no acknowledgment on the idle tab; screen: \(app.debugDescription.prefix(4000))")

        // On its board it is a Continental patch, and its page and paper card carry its number among the set's 300.
        app.tabBars.buttons["Collection"].tap()
        let patch = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "\(Self.robin), Continental edition patch, seen once")).firstMatch
        XCTAssertTrue(patch.waitForExistence(timeout: 20), "no Continental patch on the board; screen: \(app.debugDescription.prefix(4000))")
        patch.tap()
        let flip = app.buttons["card-flip"]
        XCTAssertTrue(flip.waitForExistence(timeout: 10), "the patch didn't open; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertTrue(element(app, labelled: "Continental edition, No. 226").waitForExistence(timeout: 10), "no collector number under the patch; screen: \(app.debugDescription.prefix(5000))")
        XCTAssertFalse(app.buttons["stitch-in"].exists, "reopening a patch never stitches it again")
        flip.tap()
        XCTAssertTrue(element(app, labelled: "Continental edition, number 226 of 300 in North America").waitForExistence(timeout: 10), "the paper card's heading; screen: \(app.debugDescription.prefix(5000))")
    }

    @MainActor
    func testABirdBothSetsListFoundInLosAngelesStillSewsItsCitrusPatch() throws {
        let app = try launchWithNorthAmericaDownloaded(location: "griffith")
        let row = captureAndFindTheRobin(app)
        XCTAssertEqual(row.label, "\(Self.robin), Los Angeles, New to you here", "the smaller set that lists it takes it")
        addAndSew(app, row)

        XCTAssertTrue(app.staticTexts["New patch, Citrus edition"].exists, "screen: \(app.debugDescription.prefix(4000))")
        XCTAssertTrue(app.staticTexts["Your first \(Self.robin) in Los Angeles"].exists, "screen: \(app.debugDescription.prefix(4000))")
        XCTAssertFalse(app.staticTexts["New patch, Continental edition"].exists)
        app.buttons["Done"].firstMatch.tap()

        app.tabBars.buttons["Collection"].tap()
        let patch = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "\(Self.robin), Citrus edition patch, seen once")).firstMatch
        XCTAssertTrue(patch.waitForExistence(timeout: 20), "no Citrus patch on the board; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "\(Self.robin), Continental edition patch")).firstMatch.exists, "one sighting, one patch")
    }
}
