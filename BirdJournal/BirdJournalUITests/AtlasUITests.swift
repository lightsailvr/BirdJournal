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
        XCTAssertTrue(element(app, "set-plate").exists, screen(app))
        XCTAssertTrue(app.staticTexts["157 still out there"].exists, screen(app))
        XCTAssertFalse(app.staticTexts["Not yet found here"].exists)
        let row = app.buttons.matching(identifier: "set-species-silhouette").firstMatch
        XCTAssertEqual(row.label, "001, Canada Goose, still out there")
    }

    /// One of the seeded birds, found by its number: its row has a reference photo and says "Yours", and a tap on one opens the bird.
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
    func testTheMapShowsPatchesAndATapOnOneShowsItsCallout() throws {
        let app = launch(seeded + ["-autoCardSpecies", "Sayornis nigricans", "-autoScreen", "map"])
        XCTAssertTrue(app.navigationBars["On the map"].waitForExistence(timeout: 20), screen(app))
        let callout = app.otherElements["sighting-map-callout"]
        XCTAssertTrue(callout.waitForExistence(timeout: 10), "the opening sighting's callout; \(screen(app))")
        XCTAssertTrue(callout.staticTexts["Black Phoebe"].exists, screen(app))
        XCTAssertFalse(callout.buttons["Open"].exists, "it's already open behind the sheet")
        // The finch by the sidewalk is on screen, with the pond a few hundred metres away.
        let finches = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'map-patch' AND label BEGINSWITH 'House Finch'"))
        XCTAssertTrue(finches.firstMatch.waitForExistence(timeout: 10), screen(app))
        let window = app.windows.firstMatch.frame
        let finch = try XCTUnwrap(finches.allElementsBoundByIndex.first { window.contains($0.frame) }, "no finch on screen; \(screen(app))")
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
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'map-patch' AND label BEGINSWITH 'Black Phoebe'")).firstMatch.exists, "the one the map was opened on; \(screen(app))")
        XCTAssertTrue(app.otherElements["sighting-map-callout"].staticTexts["Black Phoebe"].exists, screen(app))

        // All at one spot: no zoom would part them, so a tap lists them, and each opens.
        cluster.tap()
        let here = app.otherElements["sighting-map-here"]
        XCTAssertTrue(here.waitForExistence(timeout: 5), screen(app))
        XCTAssertTrue(here.staticTexts.matching(NSPredicate(format: "label ENDSWITH ' sightings here'")).firstMatch.exists, screen(app))
        let open = here.buttons["Open"].firstMatch
        XCTAssertTrue(open.exists, screen(app))
        open.tap()
        XCTAssertTrue(app.staticTexts["Your note"].waitForExistence(timeout: 10), "the sighting's page; \(screen(app))")
    }

    /// Issue #150's review: tap a cluster and pan straight away, at 5,000 sightings. A picture set through `MKAnnotationView.image` made MapKit
    /// cluster again and again, the main thread stayed busy for over three and a half minutes and Done didn't answer. One pan didn't always
    /// show it, three did, every time. Printed, for the PR.
    @MainActor
    func testTheMapAnswersAtFiveThousandSightings() {
        let app = XCUIApplication()
        app.launchArguments = ["-albumFile", "atlas-map-5000", "-collectionIntroShown", "YES", "-seedLarge", "5000", "-autoScreen", "map", "-autoMapAcross", "30000"]
        app.launch()
        XCTAssertTrue(app.navigationBars["On the map"].waitForExistence(timeout: 120), screen(app))
        sleep(10)  // settled, as a birder's map is by the time they touch it

        // Where things are, not a query for them: a query walks every patch on the map, which is what this test isn't timing. The seed
        // repeats, so the same cluster is here each time, up and to the left of the sighting the map opened on.
        func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate { app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)) }
        let start = Date()
        point(0.42, 0.495).tap()
        point(0.5, 0.57).press(forDuration: 0.01, thenDragTo: point(0.5, 0.23))
        point(0.8, 0.5).press(forDuration: 0.01, thenDragTo: point(0.1, 0.5))
        point(0.1, 0.34).press(forDuration: 0.01, thenDragTo: point(0.9, 0.69))
        point(0.13, 0.115).tap()  // Done
        XCTAssertTrue(app.staticTexts["Your note"].waitForExistence(timeout: 120), "Done didn't answer")
        let seconds = Date().timeIntervalSince(start)
        print("MAP-5000: a cluster's tap, three pans and Done took \(String(format: "%.1f", seconds)) s")
        XCTAssertLessThan(seconds, 60)
    }

    /// The map opens on a sighting that's among others at one spot: it stays on the map, and a tap on it lists the spot.
    @MainActor
    func testTheOpeningSightingStaysOutOfTheClustersAndListsItsSpot() {
        let app = launch(["-seedGallery", "YES", "-autoCardSpecies", "Haemorhous mexicanus", "-autoScreen", "map"])
        XCTAssertTrue(app.navigationBars["On the map"].waitForExistence(timeout: 20), screen(app))
        let patches = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'map-patch' AND label BEGINSWITH 'House Finch'"))
        XCTAssertTrue(patches.firstMatch.waitForExistence(timeout: 15), "the bird the callout names is on the map; \(screen(app))")
        XCTAssertTrue(app.otherElements["sighting-map-callout"].staticTexts["House Finch"].exists, screen(app))
        patches.firstMatch.tap()
        XCTAssertTrue(app.otherElements["sighting-map-here"].waitForExistence(timeout: 5), screen(app))
    }

    // MARK: - The record

    @MainActor
    func testARecordWithoutAPhotoLeadsWithItsPatchWhichOpensIt() {
        let app = launch(seeded + ["-autoCardSpecies", "Zenaida macroura", "-autoScreen", "sighting"])
        let patch = element(app, "sighting-patch")
        XCTAssertTrue(patch.waitForExistence(timeout: 15), screen(app))
        XCTAssertFalse(element(app, "sighting-photo").exists)
        patch.tap()
        XCTAssertFalse(element(app, "sighting-patch").waitForExistence(timeout: 2) && element(app, "sighting-patch").isHittable, "the patch's page is on top; \(screen(app))")
    }

    /// A photo at the head of the page is scaled to fill and clipped: what overflows takes no touches, so Heard and Seen and the way back
    /// still answer. The record's words change with them.
    @MainActor
    func testARecordWithAPhotoLeadsWithItAndWhatsAroundItStillAnswers() {
        let app = launch(seeded + ["-autoCardSpecies", "Sayornis nigricans", "-autoScreen", "sighting"])
        XCTAssertTrue(element(app, "sighting-photo").waitForExistence(timeout: 15), screen(app))
        XCTAssertFalse(element(app, "sighting-patch").exists)
        XCTAssertTrue(app.staticTexts["Heard with Ray-Ban Display"].exists, screen(app))
        app.buttons["Seen"].tap()
        XCTAssertTrue(app.staticTexts["Seen, and heard with Ray-Ban Display"].waitForExistence(timeout: 5), screen(app))
        XCTAssertTrue(app.staticTexts["When"].exists && app.staticTexts["Where"].exists && app.staticTexts["How"].exists, screen(app))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertFalse(element(app, "sighting-photo").waitForExistence(timeout: 2) && element(app, "sighting-photo").isHittable, "went back; \(screen(app))")
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
