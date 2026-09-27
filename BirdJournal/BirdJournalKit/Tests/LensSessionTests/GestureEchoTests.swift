import Testing
@testable import LensSession

// Phase A round trip (issue #4): one card on the lens whose text changes with every gesture the glasses deliver.
@Suite("GestureEcho")
struct GestureEchoTests {
    @Test("before any gesture the card invites a swipe or tap")
    func initialCard() {
        let echo = GestureEcho()
        #expect(echo.card == LensCard(heading: "BirdJournal", body: "Swipe or tap to test the Neural Band.", buttonLabel: "Tap me"))
        #expect(echo.count == 0)
        #expect(echo.lastGesture == nil)
    }

    /// Gesture names as the wearer performed them; the same table drives the card and the phone log.
    static let gestureNames: [(LensGesture, String)] = [
        (.swipeLeft, "Swipe left"),
        (.swipeRight, "Swipe right"),
        (.swipeUp, "Swipe up"),
        (.swipeDown, "Swipe down"),
        (.tap, "Tap"),
    ]

    @Test("each gesture is named on the card with a running count", arguments: gestureNames)
    func gestureNamesTheCard(gesture: LensGesture, name: String) {
        #expect(gesture.name == name)
        var echo = GestureEcho()
        echo.apply(gesture)
        #expect(echo.lastGesture == gesture)
        #expect(echo.count == 1)
        #expect(echo.card.heading == "BirdJournal")
        #expect(echo.card.body == "\(name) · 1 gesture")
        #expect(echo.card.buttonLabel == "Tap me")
    }

    @Test("the count keeps growing and the body names the latest gesture")
    func countAccumulates() {
        var echo = GestureEcho()
        echo.apply(.swipeLeft)
        echo.apply(.swipeLeft)
        echo.apply(.tap)
        #expect(echo.count == 3)
        #expect(echo.card.body == "Tap · 3 gestures")
    }
}
