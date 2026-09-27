/// The content of one lens card: a heading, a short body and one primary button.
public struct LensCard: Sendable, Equatable {
    public var heading: String
    public var body: String
    public var buttonLabel: String

    public init(heading: String, body: String, buttonLabel: String) {
        self.heading = heading
        self.body = body
        self.buttonLabel = buttonLabel
    }
}

/// Phase A round trip (issue #4): the card names the latest gesture and counts them, proving that Nav and Select
/// travel from the Neural Band to the phone and back to the lens. Pure state, so the adapter only renders `card`.
public struct GestureEcho: Sendable, Equatable {
    public private(set) var lastGesture: LensGesture?
    public private(set) var count = 0

    public init() {}

    public mutating func apply(_ gesture: LensGesture) {
        lastGesture = gesture
        count += 1
    }

    public var card: LensCard {
        let body = if let lastGesture {
            "\(lastGesture.name) · \(count) \(count == 1 ? "gesture" : "gestures")"
        } else {
            "Swipe or tap to test the Neural Band."
        }
        return LensCard(heading: "BirdJournal", body: body, buttonLabel: "Tap me")
    }
}

extension LensGesture {
    /// The gesture as the wearer performed it, for the card and the phone log.
    public var name: String {
        switch self {
        case .swipeLeft: "Swipe left"
        case .swipeRight: "Swipe right"
        case .swipeUp: "Swipe up"
        case .swipeDown: "Swipe down"
        case .tap: "Tap"
        }
    }
}
