import XCTest

// Debug only, like the circles: the account is off in Release (`ACCOUNTS_ENABLED`, issue #88) and the fakes are DEBUG.
#if ACCOUNTS_ENABLED && DEBUG

/// Goals (issue #65) over the debug fake circle server: a circle's page shows the goal card, and a member makes a
/// custom goal and deletes it.
final class GoalsUITests: XCTestCase {
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-fakeAccount", "signedIn", "-fakeCircles", "some"] + arguments
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    func testACirclePageShowsItsGoalCard() {
        let app = launch(["-autoScreen", "circle"])
        let monthly = element(app, "goal-monthly")
        XCTAssertTrue(monthly.waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(monthly.label.contains("goal"), monthly.label)
        XCTAssertTrue(monthly.label.contains("of 14 species"), monthly.label)
        XCTAssertTrue(monthly.label.contains("more to go"), monthly.label)

        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'goal-fake-goal'"))
        XCTAssertEqual(rows.count, 3)
        let running = rows.element(boundBy: 0).label
        XCTAssertTrue(running.contains("Fall migration") && running.contains("by Maya Ortiz") && running.contains("days left"), running)
        XCTAssertTrue(rows.element(boundBy: 1).label.contains("Big Day in Ojai"), rows.element(boundBy: 1).label)
        let ended = rows.element(boundBy: 2).label
        XCTAssertTrue(ended.contains("Owls before Halloween") && ended.contains("Reached"), ended)
        XCTAssertTrue(app.buttons["newGoal"].exists)
    }

    @MainActor
    func testAMemberMakesACustomGoalAndDeletesIt() {
        let app = launch(["-autoScreen", "circle"])
        let newGoal = app.buttons["newGoal"]
        XCTAssertTrue(newGoal.waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        newGoal.tap()

        let title = app.textFields["goalTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let create = app.buttons["createGoal"]
        XCTAssertFalse(create.isEnabled, "no title, no goal")
        title.tap()
        title.typeText("Warbler weekend")
        app.buttons["goalTarget-Increment"].firstMatch.tapIfPresent()
        create.tap()

        let made = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'goal-' AND label CONTAINS 'Warbler weekend'")).firstMatch
        XCTAssertTrue(made.waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(made.label.contains("by Pat Birder"), made.label)

        made.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        let confirm = app.buttons["Delete goal"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(made.waitForNonExistence(timeout: 5), "the goal is gone")
    }
}

private extension XCUIElement {
    func tapIfPresent() { if exists { tap() } }
}
#endif
