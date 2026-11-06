import XCTest

/// The launch splash ending while a thread sews or the painting cross-fades (issue #150, slice 6). SwiftUI draws those frames on
/// its own thread, and a frame can reach whatever the splash's end has just invalidated. When that was the `WindowGroup`'s closure,
/// which Swift 6 holds to the main actor, the app trapped. Here a Guild's goal is sewing when the splash ends, on every launch.
final class LaunchUITests: XCTestCase {
    @MainActor
    func testTheSplashEndingDuringAnAnimationDoesntEndTheApp() {
        for launch in 1...4 {
            let app = XCUIApplication()
            app.launchArguments = ["-inMemoryAlbum", "YES", "-collectionIntroShown", "YES", "-fakeAccount", "signedIn", "-fakeCircles", "some", "-autoScreen", "circles", "-splashTitleSeconds", "5", "-launchSplashShown", "NO"]
            app.launch()
            XCTAssertTrue(app.navigationBars["Guilds"].waitForExistence(timeout: 20), "launch \(launch): \(app.debugDescription.prefix(2000))")
            // The splash is 1.1 s from the first frame, and it fades over 0.5 s.
            _ = app.buttons["No such button"].waitForExistence(timeout: 4)
            XCTAssertEqual(app.state, .runningForeground, "launch \(launch) ended")
            app.terminate()
        }
    }
}
