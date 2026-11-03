import XCTest

/// Settings → About links the privacy policy and terms on the invite domain, in every build (issue #71).
final class PrivacyLinkUITests: XCTestCase {
    @MainActor
    func testSettingsLinksThePrivacyPolicy() {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES"]
        app.launch()
        app.buttons["Settings"].tap()
        // A SwiftUI Link: a link or a button, depending on the release.
        let link = app.descendants(matching: .any)["privacyPolicyLink"]
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        for _ in 0..<10 where !(link.exists && link.isHittable) { list.swipeUp() }
        XCTAssertTrue(link.exists, "no privacy policy link; screen: \(app.debugDescription.suffix(4000))")
        XCTAssertTrue(link.label.contains("Privacy policy"), link.label)
        XCTAssertTrue(app.descendants(matching: .any)["termsLink"].exists)
    }
}

// Debug only: the account is switched off in Release (`ACCOUNTS_ENABLED`, issue #88), and the fakes are DEBUG.
#if ACCOUNTS_ENABLED && DEBUG

/// Deleting the account (issue #71) with the fake account, and reporting and blocking a member over the fake circles.
final class SafetyUITests: XCTestCase {
    @MainActor
    func testDeletingTheAccountAsksOnceThenSignsOut() {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-fakeAccount", "signedIn"]
        app.launch()
        app.buttons["Settings"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Account'")).firstMatch.tap()

        let delete = app.buttons["deleteAccount"]
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        for _ in 0..<4 where !(delete.exists && delete.isHittable) { list.swipeUp() }
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "no Delete account; screen: \(app.debugDescription.prefix(3000))")
        delete.tap()

        let alert = app.alerts["Delete your account?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "no confirmation; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS \"can't be undone\"")).firstMatch.exists)
        // The fake account signs in with Apple, so the alert says Apple will ask.
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Apple will ask'")).firstMatch.exists)
        alert.buttons["Delete account"].tap()

        XCTAssertTrue(app.descendants(matching: .any)["accountDeleted"].waitForExistence(timeout: 10),
                      "no deletion notice; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.buttons["Sign in with Apple"].exists)
        XCTAssertFalse(app.buttons["Sign out"].exists)
    }

    @MainActor
    func testCancellingKeepsTheAccount() {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-fakeAccount", "signedIn"]
        app.launch()
        app.buttons["Settings"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Account'")).firstMatch.tap()
        let delete = app.buttons["deleteAccount"]
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        for _ in 0..<4 where !(delete.exists && delete.isHittable) { list.swipeUp() }
        delete.tap()
        app.alerts["Delete your account?"].buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Sign out"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testTheAccountScreenListsBlockedAccounts() {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-fakeAccount", "signedIn"]
        app.launch()
        app.buttons["Settings"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Account'")).firstMatch.tap()
        let blocked = app.buttons["Blocked accounts"]
        XCTAssertTrue(blocked.waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
        blocked.tap()
        XCTAssertTrue(app.descendants(matching: .any)["noBlocks"].waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
    }

    private func circlePage() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-fakeAccount", "signedIn", "-fakeCircles", "some", "-autoScreen", "circle",
                               "-fakePushPermission", "authorized"]
        app.launch()
        XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 10))
        return app
    }

    private func pressMaya(_ app: XCUIApplication) {
        let list = app.collectionViews.firstMatch
        let members = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Members'")).firstMatch
        for _ in 0..<24 where !(members.exists && members.isHittable) { list.swipeUp() }
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Maya Ortiz'")).firstMatch
        let mayaRow = row.exists ? row : app.staticTexts["Maya Ortiz"].firstMatch
        for _ in 0..<4 where !mayaRow.isHittable { list.swipeUp() }
        XCTAssertTrue(mayaRow.waitForExistence(timeout: 5), "no Maya; screen: \(app.debugDescription.prefix(3000))")
        mayaRow.press(forDuration: 1.0)
    }

    @MainActor
    func testReportingAMember() {
        let app = circlePage()
        pressMaya(app)
        let report = app.buttons["Report Maya Ortiz…"]
        XCTAssertTrue(report.waitForExistence(timeout: 5), "no Report; screen: \(app.debugDescription.prefix(3000))")
        report.tap()
        XCTAssertTrue(app.navigationBars["Report member"].waitForExistence(timeout: 5), "no sheet; screen: \(app.debugDescription.prefix(3000))")
        app.buttons["Harassment or bullying"].tap()
        app.buttons["reportSend"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["reportSent"].waitForExistence(timeout: 5), "not sent; screen: \(app.debugDescription.prefix(3000))")
        app.buttons["Done"].tap()
    }

    /// Every find row's label, scrolling the page from top to bottom: the list builds only the rows on screen.
    private func findLabels(_ app: XCUIApplication) -> [String] {
        let list = app.collectionViews.firstMatch
        for _ in 0..<20 { list.swipeDown() }
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'find-'"))
        var labels: [String: String] = [:]
        for _ in 0..<18 {
            for row in rows.allElementsBoundByIndex where row.exists { labels[row.identifier] = row.label }
            list.swipeUp()
        }
        return Array(labels.values)
    }

    @MainActor
    func testBlockingAMemberHidesTheirFindsAndUnblockingBringsThemBack() {
        let app = circlePage()
        XCTAssertTrue(app.buttons["Invite friends"].waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        let byMaya = { (labels: [String]) in labels.filter { $0.contains("by Maya Ortiz") } }
        XCTAssertFalse(byMaya(findLabels(app)).isEmpty, "no find of Maya's to hide")

        pressMaya(app)
        let block = app.buttons["Block Maya Ortiz…"]
        XCTAssertTrue(block.waitForExistence(timeout: 5), "no Block; screen: \(app.debugDescription.prefix(3000))")
        block.tap()
        let confirm = (app.sheets.firstMatch.exists ? app.sheets.firstMatch : app.alerts.firstMatch).buttons["Block Maya Ortiz"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "no confirmation; screen: \(app.debugDescription.prefix(3000))")
        confirm.tap()
        XCTAssertTrue(app.images["Blocked"].waitForExistence(timeout: 5) || app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Blocked'")).firstMatch.exists,
                      "not marked blocked; screen: \(app.debugDescription.prefix(3000))")
        let remaining = findLabels(app)
        XCTAssertFalse(remaining.isEmpty, "the other friends' finds should stay")
        XCTAssertEqual(byMaya(remaining), [], "Maya's finds still show")

        // Unblocking from the same menu brings them back.
        pressMaya(app)
        let unblock = app.buttons["Unblock Maya Ortiz"]
        XCTAssertTrue(unblock.waitForExistence(timeout: 5), "no Unblock; screen: \(app.debugDescription.prefix(3000))")
        unblock.tap()
        XCTAssertFalse(byMaya(findLabels(app)).isEmpty, "Maya's finds didn't come back")
    }
}
#endif
