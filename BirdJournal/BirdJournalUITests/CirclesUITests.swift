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
        app.tabBars.buttons["Guilds"].tap()
        XCTAssertTrue(app.staticTexts["Bird with your friends"].waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.buttons["Sign in with Apple"].exists)
        XCTAssertTrue(app.buttons["Sign in with Google"].exists)

        app.buttons["Sign in with Apple"].tap()
        XCTAssertTrue(app.staticTexts["No Guilds yet"].waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
    }

    /// Issue #150: with nothing known yet, the screens show the shape of what's coming, not a spinner, and the content takes
    /// its place.
    @MainActor
    func testNothingKnownYetShowsAPlaceholderUntilTheContentComes() {
        let app = launch(["-fakeAccount", "signedIn", "-fakeCircles", "some", "-fakeCircleLatency", "10"])
        app.tabBars.buttons["Guilds"].tap()
        let placeholder = app.descendants(matching: .any)["guild-placeholder"].firstMatch
        XCTAssertTrue(placeholder.waitForExistence(timeout: 8), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertEqual(placeholder.label, "Loading")
        XCTAssertEqual(app.activityIndicators.count, 0, "no spinner; screen: \(app.debugDescription.prefix(3000))")

        let sunday = app.staticTexts["Sunday Group"]
        XCTAssertTrue(sunday.waitForExistence(timeout: 20), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertFalse(placeholder.exists)
    }

    /// Issue #150: the Guilds and the finds a birder last saw are on screen at the next launch, with no connection at all, and
    /// signing out takes them off the phone.
    @MainActor
    func testTheNextLaunchDrawsTheLastKnownGuildsUntilSignOut() throws {
        let cache = ["-circleCacheFile", "guilds-\(UUID().uuidString)"]
        let app = launchOverLastKnownGuilds(cache)
        openAccount(app)
        let signOut = app.buttons["Sign out"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        signOut.tap()
        // The confirmation's own Sign out, in the dialog over the list.
        let dialog = app.sheets.firstMatch.exists ? app.sheets.firstMatch : app.alerts.firstMatch
        let confirm = dialog.buttons["Sign out"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
        confirm.tap()
        XCTAssertTrue(app.buttons["Sign in with Apple"].waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        app.terminate()
        assertNoLastKnownGuilds(cache)
    }

    /// Issue #150: deleting the account takes them off the phone too.
    @MainActor
    func testDeletingTheAccountRemovesTheLastKnownGuilds() throws {
        let cache = ["-circleCacheFile", "guilds-\(UUID().uuidString)"]
        let app = launchOverLastKnownGuilds(cache)
        openAccount(app)
        let delete = app.buttons["deleteAccount"]
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        for _ in 0..<4 where !(delete.exists && delete.isHittable) { list.swipeUp() }
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
        delete.tap()
        let alert = app.alerts["Delete your account?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
        alert.buttons["Delete account"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["accountDeleted"].waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        app.terminate()
        assertNoLastKnownGuilds(cache)
    }

    /// Reads a Guild's page over the fake server, then relaunches with no connection and finds it all still there.
    @MainActor
    private func launchOverLastKnownGuilds(_ cache: [String], file: StaticString = #filePath, line: UInt = #line) -> XCUIApplication {
        var app = launch(["-fakeAccount", "signedIn", "-fakeCircles", "some"] + cache)
        app.tabBars.buttons["Guilds"].tap()
        let group = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Sunday Group'")).firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))", file: file, line: line)
        group.tap()
        let find = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'find-'")).firstMatch
        XCTAssertTrue(app.scrolledTo(find), "screen: \(app.debugDescription.prefix(3000))", file: file, line: line)
        // The cache is written a moment after the last answer.
        Thread.sleep(forTimeInterval: 1)
        app.terminate()

        app = launch(["-fakeAccount", "signedIn", "-fakeCircles", "offline"] + cache)
        app.tabBars.buttons["Guilds"].tap()
        let again = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Sunday Group'")).firstMatch
        XCTAssertTrue(again.waitForExistence(timeout: 5), "no last-known Guild; screen: \(app.debugDescription.prefix(3000))", file: file, line: line)
        XCTAssertFalse(app.descendants(matching: .any)["guild-placeholder"].exists, file: file, line: line)
        again.tap()
        let findAgain = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'find-'")).firstMatch
        XCTAssertTrue(app.scrolledTo(findAgain), "no last-known find; screen: \(app.debugDescription.prefix(3000))", file: file, line: line)
        app.navigationBars.buttons.firstMatch.tap()
        return app
    }

    @MainActor
    private func openAccount(_ app: XCUIApplication) {
        app.tabBars.buttons["Listen"].tap()
        app.buttons["Settings"].tap()
        let account = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Account'")).firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        account.tap()
    }

    /// Signed in again with no connection, nothing is left to draw.
    @MainActor
    private func assertNoLastKnownGuilds(_ cache: [String], file: StaticString = #filePath, line: UInt = #line) {
        let app = launch(["-fakeAccount", "signedIn", "-fakeCircles", "offline"] + cache)
        app.tabBars.buttons["Guilds"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS \"Can't reach your Guilds\"")).firstMatch.waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))", file: file, line: line)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Sunday Group'")).firstMatch.exists, "the cache went with the account", file: file, line: line)
    }

    @MainActor
    func testCreatingACircleListsIt() {
        let app = launch(["-fakeAccount", "signedIn", "-fakeCircles", "empty"])
        app.tabBars.buttons["Guilds"].tap()
        XCTAssertTrue(app.staticTexts["No Guilds yet"].waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")

        app.buttons["New Guild"].tap()
        let name = app.textFields["Guild name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.typeText("Backyard Crew")
        app.buttons["Create"].tap()

        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Backyard Crew'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "not listed; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(row.label.contains("1 member"), row.label)

        row.tap()
        XCTAssertTrue(app.buttons["Invite friends"].waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.scrolledTo(app.staticTexts["Members, 1 of 20"]), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(scrolledTo(app.buttons["Leave Guild"], in: app))
    }

    /// The Guilds list (issue #118): each Guild a card with its members and this month's shared goal in species.
    @MainActor
    func testTheGuildsListShowsEachGuildsMembersAndGoal() {
        let app = launch(["-fakeAccount", "signedIn", "-fakeCircles", "some", "-autoScreen", "circles"])
        XCTAssertTrue(app.navigationBars["Guilds"].waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        let sunday = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Sunday Group'")).firstMatch
        XCTAssertTrue(sunday.waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(sunday.label.contains("4 members"), sunday.label)
        let goal = NSPredicate(format: "label BEGINSWITH 'Sunday Group' AND label CONTAINS 'species this month'")
        XCTAssertTrue(app.buttons.matching(goal).firstMatch.waitForExistence(timeout: 10), "no goal on the card: \(sunday.label)")
    }

    /// A Guild's page (issue #118): belonging first (Invite-only, Invite friends), and the birder's sharing in view.
    @MainActor
    func testAGuildPageLeadsWithBelongingAndKeepsSharingVisible() {
        let app = launch(["-fakeAccount", "signedIn", "-fakeCircles", "some", "-autoScreen", "circle"])
        XCTAssertTrue(app.buttons["Invite friends"].waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ENDSWITH 'invite-only'")).firstMatch.exists)
        let sharing = app.switches["guildShareFindsToggle"]
        XCTAssertTrue(scrolledTo(sharing, in: app), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertEqual(sharing.value as? String, "1", "sharing is on by default")
    }

    @MainActor
    func testTheInviteShowsAQRCodeOfTheLink() {
        let app = launch(["-fakeAccount", "signedIn", "-fakeCircles", "some", "-autoScreen", "circle"])
        let invite = app.buttons["Invite friends"]
        XCTAssertTrue(invite.waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(scrolledTo(invite, in: app), "screen: \(app.debugDescription.prefix(3000))")
        invite.tap()
        let code = app.images["inviteQRCode"]
        XCTAssertTrue(code.waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
        let link = code.value as? String ?? ""
        XCTAssertTrue(link.hasPrefix("https://featherguild.matthewcelia.com/i/fake-"), link)
        // It goes by the code, Share link or Copy link, and isn't printed on the sheet (issue #150).
        XCTAssertFalse(app.staticTexts[link].exists, "the link is printed on the sheet")
        let copy = app.buttons["inviteCopyLink"]
        XCTAssertTrue(copy.exists, "screen: \(app.debugDescription.prefix(3000))")
        copy.tap()
        XCTAssertTrue(app.buttons["Copied"].waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
    }

    /// The goal card (issue #65) heads a circle's page and the list draws only what's on screen: scroll down to the
    /// element.
    private func scrolledTo(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        app.scrolledTo(element)
    }

    @MainActor
    func testAnInviteLinkOpensTheJoinScreenAndJoiningOpensTheCircle() {
        let app = launch(["-fakeAccount", "signedIn", "-fakeCircles", "empty", "-autoScreen", "join", "-autoInvite", "fake-invite"])
        XCTAssertTrue(app.staticTexts["Canyon Walkers"].waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        app.buttons["Join Guild"].tap()
        XCTAssertTrue(app.staticTexts["3 members, invite-only"].waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.scrolledTo(app.staticTexts["Members, 3 of 20"]), "screen: \(app.debugDescription.prefix(3000))")
    }
}
#endif
