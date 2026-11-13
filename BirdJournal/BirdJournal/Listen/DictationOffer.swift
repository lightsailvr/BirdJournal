import SwiftUI

/// What the phone says when a photo taken on the glasses could not be named there because the glasses' microphone
/// permission is not granted (issue #194, of #185), apart from the view so the words are tested without drawing.
enum DictationOfferText {
    static let title = "Say the bird's name on your glasses"
    /// Why, and what the button does, before it does it: the permission is given in the Meta AI app, which opens.
    static let message = "After a photo on your glasses, Featherguild can hear you say the bird's name and name the sighting for you. The glasses' microphone has to be allowed for that, in the Meta AI app, which opens next. Your photos wait here to be named meanwhile."
    static let button = "Allow in Meta AI"
}

/// The offer on the run's page to turn dictation on. The lens never asks for the permission itself: that opens Meta AI on
/// a phone that is in a pocket. It goes straight to "Photo saved. Name it on your phone.", and the phone, when it is next
/// looked at, explains and offers the hop.
struct DictationOffer: View {
    let glasses: GlassesListeningSession
    @State private var isAsking = false

    var body: some View {
        ErrorNotice(DictationOfferText.title, message: DictationOfferText.message, symbol: "mic") {
            Button(DictationOfferText.button) {
                isAsking = true
                Task {
                    await glasses.allowDictation()
                    isAsking = false
                }
            }
            .disabled(isAsking)
            .accessibilityIdentifier("dictation-allow")
        }
        .accessibilityIdentifier("dictation-offer")
    }
}
