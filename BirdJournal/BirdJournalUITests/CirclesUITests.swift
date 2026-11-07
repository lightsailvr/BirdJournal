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
        XCTAssertTrue(app.staticTexts["Find wonder together."].waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        // A felt panel of patches, labelled as samples, so nobody takes them for anyone's finds.
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Sample patches'")).firstMatch.exists, "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.buttons["Sign in with Apple"].exists)
        XCTAssertTrue(app.buttons["Sign in with Google"].exists)

        app.buttons["Sign in with Apple"].tap()
        XCTAssertTrue(app.staticTexts["No Guilds yet"].waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.staticTexts["Find wonder together."].exists, "the voice stays until there's a Guild")
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

        let sunday = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Sunday Group'")).firstMatch
        XCTAssertTrue(sunday.waitForExistence(timeout: 20), "screen: \(app.debugDescription.prefix(3000))")
        // The Guilds come first, then their finds.
        XCTAssertTrue(placeholder.waitForNonExistence(timeout: 30), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertEqual(app.activityIndicators.count, 0)
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

        // One Guild: the tab is that Guild, with no step in between.
        XCTAssertTrue(app.buttons["Invite friends"].waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.staticTexts["Backyard Crew"].exists, "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.tabBars.buttons["Guilds"].isHittable, "the tab's own page, not one pushed over it")
        app.openGuildInfo()
        XCTAssertTrue(app.staticTexts["Members, 1 of 20"].waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
        let leave = app.buttons["Leave Guild"]
        XCTAssertTrue(app.scrolledInGuildInfo(to: leave))

        // Leaving goes back to no Guild at all.
        leave.tap()
        let confirm = (app.sheets.firstMatch.exists ? app.sheets.firstMatch : app.alerts.firstMatch).buttons["Leave Guild"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
        confirm.tap()
        XCTAssertTrue(app.staticTexts["No Guilds yet"].waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
    }

    /// Two Guilds: the tab opens on what's new across them, under a row of emblems that each open a Guild (issue #150, G3).
    @MainActor
    func testTwoGuildsOpenOnWhatsNewAcrossThem() {
        let app = launch(["-fakeAccount", "signedIn", "-fakeCircles", "shared"])
        app.tabBars.buttons["Guilds"].tap()
        // Jo's hummingbird is in both Guilds: one row, naming both.
        let shared = app.buttons["find-00000000-0000-4000-8000-000000000001"]
        XCTAssertTrue(app.scrolledTo(shared, limit: 12), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(shared.label.contains("In Sunday Group and Family"), shared.label)
        XCTAssertEqual(app.buttons.matching(identifier: "find-00000000-0000-4000-8000-000000000001").count, 1)
        // Each find names its Guilds.
        let sams = app.buttons["find-00000000-0000-4000-8000-000000000003"]
        XCTAssertTrue(sams.label.contains("In Sunday Group"), sams.label)
        XCTAssertFalse(sams.label.contains("Family"), sams.label)

        for _ in 0..<12 where !app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Family,'")).firstMatch.isHittable { app.swipeDown() }
        let family = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Family,'")).firstMatch
        XCTAssertTrue(family.isHittable, "screen: \(app.debugDescription.prefix(3000))")
        family.tap()
        XCTAssertTrue(app.buttons["Invite friends"].waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.staticTexts["Family"].exists, "screen: \(app.debugDescription.prefix(3000))")
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
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'invite-only'")).firstMatch.exists)
        // One line states the setting, and opens the sheet it lives in.
        let line = app.buttons["guildSharingLine"]
        XCTAssertTrue(line.exists, "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(line.label.contains("Sharing your finds automatically"), line.label)
        line.tap()
        let sharing = app.switches["guildShareFindsToggle"]
        XCTAssertTrue(sharing.waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertEqual(sharing.value as? String, "1", "sharing is on by default")
    }

    /// The Info sheet holds what moved off the page (issue #150, G2).
    @MainActor
    func testTheInfoSheetHoldsWhatMovedThere() {
        let app = launch(["-fakeAccount", "signedIn", "-fakeCircles", "some", "-autoScreen", "circle", "-fakePushPermission", "authorized"])
        XCTAssertTrue(app.buttons["Invite friends"].waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        // None of it is on the page.
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Members'")).firstMatch.exists)
        XCTAssertFalse(app.buttons["Leave Guild"].exists)
        XCTAssertFalse(app.buttons["newGoal"].exists)

        app.openGuildInfo()
        XCTAssertTrue(app.descendants(matching: .any)["goal-monthly"].waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.scrolledInGuildInfo(to: app.buttons["newGoal"]))
        XCTAssertTrue(app.scrolledInGuildInfo(to: app.switches["guildShareFindsToggle"]))
        XCTAssertTrue(app.scrolledInGuildInfo(to: app.staticTexts["Maya Ortiz"].firstMatch), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.scrolledInGuildInfo(to: app.switches["Mute this Guild"]))
        XCTAssertTrue(app.scrolledInGuildInfo(to: app.buttons["Leave Guild"]))
    }

    /// "All goals" goes to the goals.
    @MainActor
    func testAllGoalsOpensTheGoals() {
        let app = launch(["-fakeAccount", "signedIn", "-fakeCircles", "some", "-autoScreen", "circle"])
        let all = app.buttons["guildAllGoals"]
        XCTAssertTrue(all.waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        all.tap()
        XCTAssertTrue(app.staticTexts["Fall migration"].waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
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

    /// The page draws only what's near the screen: scroll down to the element.
    private func scrolledTo(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        app.scrolledTo(element)
    }

    @MainActor
    func testAnInviteLinkOpensTheJoinScreenAndJoiningOpensTheCircle() {
        let app = launch(["-fakeAccount", "signedIn", "-fakeCircles", "empty", "-autoScreen", "join", "-autoInvite", "fake-invite"])
        XCTAssertTrue(app.staticTexts["Canyon Walkers"].waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        // Who invited you, patches labelled as samples, and nothing of the Guild's own finds (issue #150, G8).
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Invited by Maya Ortiz'")).firstMatch.exists, "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Sample patches'")).firstMatch.exists, "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'find-'")).count, 0)
        app.buttons["Join Guild"].tap()
        // The only Guild, so the tab is its page, with nothing to go back to.
        let invite = app.buttons["Invite friends"]
        XCTAssertTrue(invite.waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '3 members, invite-only'")).firstMatch.exists, "screen: \(app.debugDescription.prefix(3000))")
        app.openGuildInfo()
        XCTAssertTrue(app.staticTexts["Members, 3 of 20"].waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
    }
}
#endif
