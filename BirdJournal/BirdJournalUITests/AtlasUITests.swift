import XCTest

/// The Atlas as a book (issue #150, slice 9), through real taps: plates, a set's rows, patches on the map and a sighting's record.
final class AtlasUITests: XCTestCase {
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-collectionIntroShown", "YES"] + arguments
        app.launch()
        return app
    }

    private let seeded = ["-seedJournal", "YES"]

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func screen(_ app: XCUIApplication) -> String { "screen: \(app.debugDescription.prefix(3000))" }

    // MARK: - A set's page

    @MainActor
    func testASetsPageIsAPlateThenOneCountThenItsRows() {
        let app = launch(seeded + ["-autoScreen", "set"])
        XCTAssertTrue(app.staticTexts["Los Angeles"].waitForExistence(timeout: 15), screen(app))
        XCTAssertTrue(app.staticTexts["Citrus edition, 160 birds"].exists, screen(app))
        XCTAssertTrue(app.staticTexts["3 of 160 sewn"].exists, screen(app))
        XCTAssertTrue(app.staticTexts["AI illustration"].exists || element(app, "set-plate").exists, screen(app))
        XCTAssertTrue(app.staticTexts["157 still out there"].exists, screen(app))
        XCTAssertFalse(app.staticTexts["Not yet found here"].exists)
        let row = app.buttons.matching(identifier: "set-species-silhouette").firstMatch
        XCTAssertEqual(row.label, "001, Canada Goose, still out there")
    }

    /// One of the seeded birds, found by its number: patch rows say "Yours", and a tap on one opens the bird.
    @MainActor
    func testAFoundBirdsRowSaysItsYoursAndOpensTheBird() {
        let app = launch(seeded + ["-autoScreen", "set"])
        let rows = app.buttons.matching(identifier: "set-species-silhouette")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15), screen(app))
        let dove = app.buttons.matching(NSPredicate(format: "label ENDSWITH 'Mourning Dove, yours, seen once'")).firstMatch
        for _ in 0..<20 where !dove.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(dove.isHittable, screen(app))
        dove.tap()
        XCTAssertTrue(app.staticTexts["Zenaida macroura"].waitForExistence(timeout: 10), screen(app))
    }

    /// A set whose pack isn't on the phone has rows too, with the glyph, and says what a download adds.
    @MainActor
    func testASetWhosePackIsNotOnThePhoneStillShowsItsBirds() {
        let app = launch(seeded + ["-autoScreen", "set", "-autoSet", "us-ca-sd"])
        let row = app.buttons.matching(identifier: "set-species-silhouette").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), screen(app))
        XCTAssertTrue(row.label.hasPrefix("001, "), row.label)
        XCTAssertTrue(row.label.hasSuffix(", still out there"), row.label)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'field guide isn'")).firstMatch.exists, screen(app))
    }

    /// The cover is scaled to fill and clipped: what overflows its plate takes no touches, so a tap on a plate opens that plate's set,
    /// at its edge next to the plate above.
    @MainActor
    func testATapOnAPlatesEdgeOpensThatPlatesSet() {
        let app = launch(["-autoScreen", "guide"])
        let losAngeles = app.buttons["guide-set-us-ca-la"]
        XCTAssertTrue(losAngeles.waitForExistence(timeout: 15), screen(app))
        losAngeles.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)).tap()
        XCTAssertTrue(app.staticTexts["157 still out there"].waitForExistence(timeout: 10) || app.staticTexts["160 still out there"].waitForExistence(timeout: 5), screen(app))
        XCTAssertTrue(app.staticTexts["Citrus edition, 160 birds"].exists, screen(app))
        app.navigationBars.buttons.firstMatch.tap()

        let sanDiego = app.buttons["guide-set-us-ca-sd"]
        XCTAssertTrue(sanDiego.waitForExistence(timeout: 15), screen(app))
        if sanDiego.frame.minY > app.windows.firstMatch.frame.height - 200 { app.swipeUp() }
        sanDiego.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Coastal edition'")).firstMatch.waitForExistence(timeout: 10), screen(app))
    }

    // MARK: - The map

    @MainActor
    func testTheMapShowsPatchesAndATapOnOneShowsItsCallout() {
        let app = launch(seeded + ["-autoCardSpecies", "Sayornis nigricans", "-autoScreen", "map"])
        XCTAssertTrue(app.navigationBars["On the map"].waitForExistence(timeout: 20), screen(app))
        let callout = app.otherElements["sighting-map-callout"]
        XCTAssertTrue(callout.waitForExistence(timeout: 10), "the opening sighting's callout; \(screen(app))")
        XCTAssertTrue(callout.staticTexts["Black Phoebe"].exists, screen(app))
        XCTAssertFalse(callout.buttons["Open"].exists, "it's already open behind the sheet")
        // The finch by the sidewalk is on screen, with the pond a few hundred metres away.
        let finch = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'map-patch' AND label BEGINSWITH 'House Finch'")).firstMatch
        XCTAssertTrue(finch.waitForExistence(timeout: 10), screen(app))
        finch.tap()
        XCTAssertTrue(callout.staticTexts["House Finch"].waitForExistence(timeout: 5), screen(app))
        XCTAssertTrue(callout.buttons["Open"].exists, screen(app))
        callout.buttons["Open"].tap()
        XCTAssertTrue(app.staticTexts["Haemorhous mexicanus"].waitForExistence(timeout: 10), screen(app))
    }

    /// Thirty birds at one spot: MapKit gathers them. The one the map was opened on, by the pond, stays out.
    @MainActor
    func testSightingsTooCloseToTellApartAreOneCluster() {
        let app = launch(seeded + ["-seedBoard", "YES", "-autoCardSpecies", "Sayornis nigricans", "-autoScreen", "map", "-autoMapAcross", "3000"])
        XCTAssertTrue(app.navigationBars["On the map"].waitForExistence(timeout: 20), screen(app))
        let cluster = element(app, "map-patch-cluster")
        XCTAssertTrue(cluster.waitForExistence(timeout: 15), screen(app))
        XCTAssertTrue(cluster.label.contains(" sightings, the newest "), cluster.label)
        XCTAssertTrue(element(app, "map-patch").exists, "the one the map was opened on; \(screen(app))")
    }

    // MARK: - The record

    @MainActor
    func testARecordWithoutAPhotoLeadsWithItsPatchWhichOpensIt() {
        let app = launch(seeded + ["-autoCardSpecies", "Zenaida macroura", "-autoScreen", "sighting"])
        let patch = element(app, "record-patch")
        XCTAssertTrue(patch.waitForExistence(timeout: 15), screen(app))
        XCTAssertFalse(element(app, "record-photo").exists)
        patch.tap()
        XCTAssertFalse(element(app, "record-patch").waitForExistence(timeout: 2) && element(app, "record-patch").isHittable, "the patch's page is on top; \(screen(app))")
    }

    /// A photo at the head of the page is scaled to fill and clipped: what overflows takes no touches, so Heard and Seen and the way back
    /// still answer. The record's words change with them.
    @MainActor
    func testARecordWithAPhotoLeadsWithItAndWhatsAroundItStillAnswers() {
        let app = launch(seeded + ["-autoCardSpecies", "Sayornis nigricans", "-autoScreen", "sighting"])
        XCTAssertTrue(element(app, "record-photo").waitForExistence(timeout: 15), screen(app))
        XCTAssertFalse(element(app, "record-patch").exists)
        XCTAssertTrue(app.staticTexts["Heard with Ray-Ban Display"].exists, screen(app))
        app.buttons["Seen"].tap()
        XCTAssertTrue(app.staticTexts["Seen, and heard with Ray-Ban Display"].waitForExistence(timeout: 5), screen(app))
        XCTAssertTrue(app.staticTexts["When"].exists && app.staticTexts["Where"].exists && app.staticTexts["How"].exists, screen(app))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertFalse(element(app, "record-photo").waitForExistence(timeout: 2) && element(app, "record-photo").isHittable, "went back; \(screen(app))")
    }

    @MainActor
    func testARecordKeepsRarityAndIdentificationUntilYouAskAndARemovalIsConfirmed() {
        let app = launch(seeded + ["-autoCardSpecies", "Sayornis nigricans", "-autoScreen", "sighting"])
        let rarity = app.buttons["Rarity"]
        for _ in 0..<12 where !(rarity.exists && rarity.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(rarity.isHittable, screen(app))
        XCTAssertFalse(element(app, "card-rarity").exists, "tucked away")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Model score'")).firstMatch.exists, "tucked away")
        rarity.tap()
        XCTAssertTrue(element(app, "card-rarity").waitForExistence(timeout: 5), screen(app))
        let identification = app.buttons["Identification"]
        for _ in 0..<4 where !identification.isHittable {
            app.swipeUp()
        }
        identification.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Model score'")).firstMatch.waitForExistence(timeout: 5), screen(app))

        let remove = app.buttons["Remove from collection"]
        for _ in 0..<6 where !remove.isHittable {
            app.swipeUp()
        }
        remove.tap()
        XCTAssertTrue(app.staticTexts["Remove this sighting?"].waitForExistence(timeout: 5), screen(app))
        XCTAssertTrue(app.buttons["Remove"].exists, screen(app))
    }
}
