import XCTest

/// A Guild's page (issue #118) leads with its cover, emblem, members and Invite, then the goals, so the feed, the
/// members and the settings sit further down, and the list builds only the rows on screen.
extension XCUIApplication {
    /// Swipes up until `element` exists and is hittable, at most `limit` times; whether it got there.
    @discardableResult
    func scrolledTo(_ element: XCUIElement, limit: Int = 20) -> Bool {
        for _ in 0..<limit where !(element.exists && element.isHittable) { swipeUp() }
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
