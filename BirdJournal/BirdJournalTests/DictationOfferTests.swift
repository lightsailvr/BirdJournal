import SwiftUI
import Testing
@testable import BirdJournal

// Issue #194 (of #185): the phone's offer to turn dictation on, which the run's page shows when a photo taken on the
// glasses could not be named there for want of their microphone permission. The lens never asks: asking opens Meta AI.
extension ScreenAccessibilityTests {
    @Test("the offer to say a bird's name on the glasses says what it is for and where the button leads before it leads there, at both text sizes", arguments: sizes)
    func dictationOffer(typeSize: DynamicTypeSize) async throws {
        let harness = try Harness()
        let labels = try await Self.walk(DictationOffer(glasses: harness.run.glasses), harness: harness, typeSize: typeSize) { $0.contains(DictationOfferText.button) }
        Self.expectClean(labels, screen: "the dictation offer")
        Self.expectOneWordPerThing(labels, screen: "the dictation offer")
        #expect(labels == [DictationOfferText.title, DictationOfferText.message, DictationOfferText.button])
        #expect(DictationOfferText.message.contains("in the Meta AI app, which opens next"), "the hop is announced before it happens")
        #expect(DictationOfferText.button == "Allow in Meta AI")
    }
}
