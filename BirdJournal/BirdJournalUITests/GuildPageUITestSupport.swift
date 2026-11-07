import XCTest

/// A Guild's page leads with its emblem, members and Invite, then the goal, so the feed sits further down, and the page builds
/// only the rows near the screen. The goals, the members and the settings are in its Info sheet (issue #150).
extension XCUIApplication {
    /// Swipes up until `element` exists and is hittable, at most `limit` times; whether it got there.
    @discardableResult
    func scrolledTo(_ element: XCUIElement, limit: Int = 20) -> Bool {
        for _ in 0..<limit where !(element.exists && element.isHittable) { swipeUp() }
        return element.exists && element.isHittable
    }

    /// The Info sheet on a Guild's page.
    func openGuildInfo(file: StaticString = #filePath, line: UInt = #line) {
        let info = buttons["guildInfo"]
        XCTAssertTrue(info.waitForExistence(timeout: 10), "no Info; screen: \(debugDescription.prefix(3000))", file: file, line: line)
        info.tap()
        XCTAssertTrue(navigationBars.buttons["Done"].waitForExistence(timeout: 5), "no sheet; screen: \(debugDescription.prefix(3000))", file: file, line: line)
    }

    /// Scrolls the Info sheet's list until `element` can be touched; whether it got there.
    @discardableResult
    func scrolledInGuildInfo(to element: XCUIElement, limit: Int = 12) -> Bool {
        let list = collectionViews.firstMatch
        for _ in 0..<limit where !(element.exists && element.isHittable) { list.swipeUp() }
        return element.exists && element.isHittable
    }

    /// Every find row's label in feed order, scrolling the page from top to bottom.
    func feedLabels(swipes: Int = 16) -> [String] {
        let rows = descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'find-'"))
        var labels: [(String, String)] = []
        for _ in 0..<swipes {
            for row in rows.allElementsBoundByIndex where row.exists && !labels.contains(where: { $0.0 == row.identifier }) {
                labels.append((row.identifier, row.label))
            }
            swipeUp()
        }
        return labels.map(\.1)
    }
}
