import XCTest

// Debug only, like the circles: the account is off in Release (`ACCOUNTS_ENABLED`, issue #88) and the fakes are DEBUG.
#if ACCOUNTS_ENABLED && DEBUG

/// Finds (issue #62) over the debug fake circle server: a circle's page shows its Recent finds with their marks, and
/// Settings → Account has "Share my finds automatically", on by default.
final class FindsUITests: XCTestCase {
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES"] + arguments
        app.launch()
        return app
    }

    @MainActor
    func testACirclePageShowsItsRecentFinds() {
        let app = launch(["-fakeAccount", "signedIn", "-fakeCircles", "some", "-autoScreen", "circle"])
        XCTAssertTrue(app.buttons["Invite friends"].waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")

        // The Guild's header and goal sit above the finds: the page builds
        // only the rows near the screen, so read them while scrolling.
        let labels = app.feedLabels()
        XCTAssertGreaterThanOrEqual(labels.count, 4, "\(labels)")
        let newest = labels[0]
        XCTAssertTrue(newest.contains("California Gnatcatcher"), newest)
        XCTAssertTrue(newest.contains("At a secret spot"), newest)
        XCTAssertTrue(newest.contains("First for the Guild"), newest)
        XCTAssertTrue(newest.contains("Rare"), newest)
        let oldest = labels[3]
        XCTAssertTrue(oldest.contains("Seen by Maya Ortiz") && oldest.contains("New patch") && oldest.contains("First for the Guild"), oldest)
        let later = labels[1]
        XCTAssertTrue(later.contains("Black Phoebe") && !later.contains("First for the Guild"), later)
        // A repeat sighting is a quieter line (issue #136).
        XCTAssertTrue(later.contains("Heard again by Jo Park") && !later.contains("New patch"), later)
    }

    private static let mayasPhoebe = "00000000-0000-4000-8000-000000000000"
    private static let samsGnatcatcher = "00000000-0000-4000-8000-000000000003"

    /// A friend's find opens, by a real tap on its patch, and turns over to the paper card (issue #150, F1).
    @MainActor
    func testAFriendsFindOpensAndTurnsOver() {
        let app = launch(["-fakeAccount", "signedIn", "-fakeCircles", "some", "-autoScreen", "circle"])
        let row = app.buttons["find-\(Self.mayasPhoebe)"]
        XCTAssertTrue(app.scrolledTo(row, limit: 24), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(row.label.contains("Black Phoebe"), row.label)
        // On the patch itself, at the row's left: a clipped picture must not swallow it.
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()

        XCTAssertTrue(app.navigationBars["Maya's find"].waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertEqual(app.staticTexts["find-page-name"].label, "Black Phoebe")
        XCTAssertTrue(app.staticTexts["Maya Ortiz sewed a new patch"].exists, "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.staticTexts["find-page-where"].label.hasPrefix("Seen in Pasadena, "), app.staticTexts["find-page-where"].label)
        XCTAssertTrue(app.descendants(matching: .any)["find-page-marks"].label.contains("First for the Guild"))
        // The reactions come along, and are the same ones as the feed's.
        let lovely = app.buttons["react-lovely-\(Self.mayasPhoebe)"]
        XCTAssertEqual(lovely.value as? String, "2 reactions")
        XCTAssertFalse(app.tabBars.buttons["Guilds"].isHittable, "the object gets the whole height")

        let flip = app.buttons["card-flip"]
        XCTAssertTrue(flip.exists, "the LA pack describes this bird")
        flip.tap()
        XCTAssertEqual(flip.value as? String, "Paper card")
        XCTAssertEqual(app.staticTexts["card-name"].label, "Black Phoebe")
        XCTAssertTrue(app.staticTexts["card-story-title"].exists, "its story, from the viewer's pack")
        // No history: these aren't this birder's sightings.
        XCTAssertFalse(app.descendants(matching: .any)["card-history"].exists)
        flip.tap()
        XCTAssertEqual(flip.value as? String, "Patch")

        // A reaction here shows on the feed on the way back.
        lovely.tap()
        XCTAssertTrue(lovely.wait(for: \.isSelected, toEqual: true, timeout: 5))
        XCTAssertGreaterThanOrEqual(lovely.frame.height, 44)
        app.navigationBars.buttons.firstMatch.tap()
        let feedLovely = app.buttons["react-lovely-\(Self.mayasPhoebe)"]
        XCTAssertTrue(feedLovely.waitForExistence(timeout: 5))
        XCTAssertEqual(feedLovely.value as? String, "3 reactions")
    }

    /// The Atlas's profile, and the birder's own patch once they have one.
    @MainActor
    func testAFindLinksToTheAtlasAndToYourPatch() {
        let app = launch(["-fakeAccount", "signedIn", "-fakeCircles", "some", "-autoScreen", "find", "-autoFind", "maya/\(Self.mayasPhoebe)", "-seedJournal", "YES", "-collectionIntroShown", "YES"])
        let atlas = app.buttons["find-page-atlas"]
        XCTAssertTrue(atlas.waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(3000))")
        let yours = app.buttons["find-page-yours"]
        XCTAssertTrue(app.scrolledTo(yours, limit: 4), "the seeded journal has this bird's patch; screen: \(app.debugDescription.prefix(3000))")
        yours.tap()
        XCTAssertTrue(app.descendants(matching: .any)["patch-count"].waitForExistence(timeout: 5), "the birder's own page; screen: \(app.debugDescription.prefix(3000))")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.scrolledTo(atlas, limit: 4))
        atlas.tap()
        XCTAssertTrue(app.staticTexts["Sayornis nigricans"].waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
    }

    /// Without a patch of your own, there's no link to one: no patch until you've found the bird.
    @MainActor
    func testAFindHasNoLinkToAPatchYouDontHave() {
        let app = launch(["-fakeAccount", "signedIn", "-fakeCircles", "some", "-autoScreen", "find", "-autoFind", "maya/\(Self.mayasPhoebe)"])
        XCTAssertTrue(app.buttons["find-page-atlas"].waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertFalse(app.buttons["find-page-yours"].exists)
    }

    /// Opening a find never says more of where the bird was than the feed does.
    @MainActor
    func testASecretSpotStaysSecret() {
        let app = launch(["-fakeAccount", "signedIn", "-fakeCircles", "some", "-autoScreen", "circle"])
        let row = app.buttons["find-\(Self.samsGnatcatcher)"]
        XCTAssertTrue(app.scrolledTo(row, limit: 24), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(row.label.contains("At a secret spot"), row.label)
        row.tap()
        let place = app.staticTexts["find-page-where"]
        XCTAssertTrue(place.waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(place.label.hasPrefix("Heard at a secret spot, "), place.label)
        XCTAssertEqual(app.maps.count, 0)
    }

    /// A quiet repeat line opens the same page, and a bird the viewer's pack doesn't describe has its name and no card, on the
    /// edition's blank (issue #150, F1).
    @MainActor
    func testABirdNoPackDescribesHasItsNameAndNoCard() {
        let app = launch(["-fakeAccount", "signedIn", "-fakeCircles", "shared", "-autoScreen", "find", "-autoFind", "lee/00000000-0000-4000-8000-000000000014"])
        XCTAssertTrue(app.staticTexts["find-page-name"].waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertEqual(app.staticTexts["find-page-name"].label, "Black-vented Shearwater")
        XCTAssertFalse(app.buttons["card-flip"].exists, "no card without the pack")
    }

    /// Repeats by one member gather into one line that opens in place, each with its own reactions and page. A marked find stays out.
    @MainActor
    func testRepeatsGatherIntoALineThatOpensInPlace() {
        let app = launch(["-fakeAccount", "signedIn", "-fakeCircles", "shared", "-autoScreen", "circles"])
        let first = "00000000-0000-4000-8000-000000000010"
        let line = app.buttons["repeats-\(first)"]
        XCTAssertTrue(line.waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(line.label.contains("Lee Birder found 3 birds again"), line.label)
        XCTAssertTrue(line.label.contains("House Finch and Mourning Dove"), line.label)
        XCTAssertEqual(line.value as? String, "Closed")
        XCTAssertFalse(app.buttons["find-\(first)"].exists, "gathered")
        // Sam's Rare gnatcatcher is a repeat too, and stands on its own.
        XCTAssertTrue(app.scrolledTo(app.buttons["find-\(Self.samsGnatcatcher)"], limit: 6))
        for _ in 0..<6 where !line.isHittable { app.swipeDown() }

        line.tap()
        XCTAssertEqual(line.value as? String, "Open")
        let lovely = app.buttons["react-lovely-\(first)"]
        XCTAssertTrue(lovely.waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.scrolledTo(lovely, limit: 4))
        lovely.tap()
        XCTAssertTrue(lovely.wait(for: \.isSelected, toEqual: true, timeout: 5), "react to a single repeat")

        let quiet = app.buttons["find-\(first)"]
        quiet.tap()
        XCTAssertTrue(app.navigationBars["Lee's find"].waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertEqual(app.staticTexts["find-page-name"].label, "House Finch")
    }

    /// Report and Block sit in a find's page's menu, and a block takes the find off the page and the feed.
    @MainActor
    func testBlockingFromAFindsPageTakesThemAway() {
        let app = launch(["-fakeAccount", "signedIn", "-fakeCircles", "some", "-autoScreen", "circle"])
        let row = app.buttons["find-\(Self.mayasPhoebe)"]
        XCTAssertTrue(app.scrolledTo(row, limit: 24), "screen: \(app.debugDescription.prefix(3000))")
        row.tap()
        let menu = app.buttons["find-page-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
        menu.tap()
        XCTAssertTrue(app.buttons["Report this find…"].waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
        app.buttons["Block Maya Ortiz…"].tap()
        let confirm = (app.sheets.firstMatch.exists ? app.sheets.firstMatch : app.alerts.firstMatch).buttons["Block Maya Ortiz"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
        confirm.tap()
        XCTAssertTrue(app.buttons["Invite friends"].waitForExistence(timeout: 10) || app.buttons["guildInfo"].waitForExistence(timeout: 5), "back on the Guild; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertEqual(app.feedLabels(swipes: 8).filter { $0.contains("by Maya Ortiz") }, [], "Maya's finds still show")
    }

    @MainActor
    func testSharingIsOnByDefaultAndOffIsPrivate() {
        let app = launch(["-fakeAccount", "signedIn"])
        app.buttons["Settings"].tap()
        let toggle = app.switches["shareFindsToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertEqual(toggle.value as? String, "1", "on by default")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'never with the exact spot'")).firstMatch.exists)

        // The setting is the app's own default: put it back however the test ends.
        defer { if toggle.value as? String == "0" { toggle.switches.firstMatch.tap() } }
        toggle.switches.firstMatch.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'stay on this iPhone'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0")
    }
}
#endif
