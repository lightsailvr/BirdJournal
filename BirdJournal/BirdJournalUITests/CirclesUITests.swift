import XCTest

// Debug only: circles need the account, switched off in Release (`ACCOUNTS_ENABLED`, issue #88), and the fakes are DEBUG.
#if ACCOUNTS_ENABLED && DEBUG

/// The Circle tab (issue #61) over the debug fake circle server (`-fakeCircles`) and fake account (`-fakeAccount`):
/// signed out it invites the birder to sign in; signed in, a new circle is listed; an invite link opens the join
/// screen, and joining opens the circle.
final class CirclesUITests: XCTestCase {
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES"] + arguments
        app.launch()
        return app
    }

    @MainActor
    func testSignedOutTheTabInvitesTheBirderToSignIn() {
        let app = launch(["-fakeAccount", "signedOut", "-fakeCircles", "empty"])
        app.tabBars.buttons["Circles"].tap()
        XCTAssertTrue(app.staticTexts["Bird with your friends"].waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.buttons["Sign in with Apple"].exists)
        XCTAssertTrue(app.buttons["Sign in with Google"].exists)

        app.buttons["Sign in with Apple"].tap()
        XCTAssertTrue(app.staticTexts["No circles yet"].waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
    }

    @MainActor
    func testCreatingACircleListsIt() {
        let app = launch(["-fakeAccount", "signedIn", "-fakeCircles", "empty"])
        app.tabBars.buttons["Circles"].tap()
        XCTAssertTrue(app.staticTexts["No circles yet"].waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")

        app.buttons["New circle"].tap()
        let name = app.textFields["Circle name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.typeText("Backyard Crew")
        app.buttons["Create"].tap()

        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Backyard Crew'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "not listed; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(row.label.contains("1 member"), row.label)

        row.tap()
        XCTAssertTrue(app.staticTexts["Members · 1 of 20"].waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.buttons["Invite friends"].exists)
        XCTAssertTrue(scrolledTo(app.buttons["Leave circle"], in: app))
    }

    @MainActor
    func testTheInviteShowsAQRCodeOfTheLink() {
        let app = launch(["-fakeAccount", "signedIn", "-fakeCircles", "some", "-autoScreen", "circle"])
        let invite = app.buttons["Invite friends"]
        XCTAssertTrue(app.buttons["newGoal"].waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(scrolledTo(invite, in: app), "screen: \(app.debugDescription.prefix(3000))")
        invite.tap()
        let code = app.images["inviteQRCode"]
        XCTAssertTrue(code.waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
        let link = code.value as? String ?? ""
        XCTAssertTrue(link.hasPrefix("https://birdquest.matthewcelia.com/i/fake-"), link)
        XCTAssertTrue(app.staticTexts[link].exists, "the link under the code isn't the code's URL")
    }

    /// The goal card (issue #65) heads a circle's page and the list draws only what's on screen: scroll down to the
    /// element.
    private func scrolledTo(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<6 where !element.isHittable { app.swipeUp() }
        return element.isHittable
    }

    @MainActor
    func testAnInviteLinkOpensTheJoinScreenAndJoiningOpensTheCircle() {
        let app = launch(["-fakeAccount", "signedIn", "-fakeCircles", "empty", "-autoScreen", "join", "-autoInvite", "fake-invite"])
        XCTAssertTrue(app.staticTexts["Canyon Walkers"].waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        app.buttons["Join circle"].tap()
        XCTAssertTrue(app.staticTexts["Members · 3 of 20"].waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
    }
}
#endif
