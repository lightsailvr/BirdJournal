import CoreGraphics
import Testing
@testable import BirdJournal

// The full-screen photo's zoom, as numbers (`PhotoZoom`, behind `OriginalPhotoView`): how far a pinch can go on a photo of a
// given size, the steps VoiceOver's actions take, and what it hears of them. The pinch itself is the system's scroll view's,
// and `IdleCaptureUITests` double-taps the real one.
@Suite("Photo zoom")
struct PhotoZoomTests {
    @Test("A phone's photo zooms to twice its own pixels, and a small photo still comes four times closer")
    func maximum() {
        // 4032 pixels across the 402 points of a 3× screen: pixel for pixel at 3.34 times, so twice that.
        #expect(abs(PhotoZoom.maximum(pixels: 4_032, points: 402, displayScale: 3) - 6.687) < 0.01)
        // A glasses photo's 1080 pixels are fewer than the screen's own.
        #expect(PhotoZoom.maximum(pixels: 1_080, points: 402, displayScale: 3) == PhotoZoom.leastMaximum)
        // Before the view has a size there is nothing to divide by.
        #expect(PhotoZoom.maximum(pixels: 4_032, points: 0, displayScale: 3) == PhotoZoom.leastMaximum)
        #expect(PhotoZoom.doubleTap <= PhotoZoom.leastMaximum, "a double tap never asks for more than any photo has")
    }

    @Test("VoiceOver's zoom doubles going in and halves coming out, between the whole photo and the furthest zoom")
    func steps() {
        #expect(PhotoZoom.stepped(from: 1, in: true, maximum: 6.5) == 2)
        #expect(PhotoZoom.stepped(from: 2, in: true, maximum: 6.5) == 4)
        #expect(PhotoZoom.stepped(from: 4, in: true, maximum: 6.5) == 6.5)
        #expect(PhotoZoom.stepped(from: 6.5, in: true, maximum: 6.5) == 6.5, "no step past the end")
        #expect(PhotoZoom.stepped(from: 6.5, in: false, maximum: 6.5) == 3.25)
        #expect(PhotoZoom.stepped(from: 1.5, in: false, maximum: 6.5) == 1)
        #expect(PhotoZoom.stepped(from: 1, in: false, maximum: 6.5) == 1, "nor before the whole photo")
    }

    @Test("VoiceOver hears the zoom in times, and the whole photo by name")
    func spoken() {
        #expect(PhotoZoom.spoken(1) == "Whole photo")
        #expect(PhotoZoom.spoken(1.004) == "Whole photo", "a pinch's rounding is not a zoom")
        #expect(PhotoZoom.spoken(3) == "3 times zoom")
        #expect(PhotoZoom.spoken(2.6) == "2.6 times zoom")
        #expect(!PhotoZoom.isZoomed(1) && PhotoZoom.isZoomed(1.5))
    }
}
