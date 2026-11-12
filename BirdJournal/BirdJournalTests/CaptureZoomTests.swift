import Foundation
import Testing
@testable import BirdJournal

// Issue #187 (of #185): the capture camera's zoom, as a value. What a rear camera says about itself (`RearCameraFacts`, read
// from AVFoundation on a phone) becomes the lens buttons a birder reads and the range a pinch runs through.
@Suite("Capture zoom")
struct CaptureZoomTests {
    typealias Lens = RearCameraFacts.Lens

    /// An iPhone 17 Pro's rear camera as AVFoundation describes it: three lenses behind one device whose own factor 1 is the
    /// ultra-wide, the wide taking over at 2 and the telephoto at 8, shown to a person at half; each has a 48 MP sensor,
    /// which gives a full-quality crop at twice the lens's own start.
    static let iPhone17Pro = RearCameraFacts(
        minimum: 1, maximum: 189,
        lenses: [Lens(start: 1, fullQualityCrops: [2]), Lens(start: 2, fullQualityCrops: [2]), Lens(start: 8, fullQualityCrops: [2])],
        displayMultiplier: 0.5
    )
    /// A phone with an ultra-wide and a 48 MP wide lens.
    static let twoLenses = RearCameraFacts(minimum: 1, maximum: 20, lenses: [Lens(start: 1), Lens(start: 2, fullQualityCrops: [2])], displayMultiplier: 0.5)
    /// A phone with one 12 MP lens.
    static let oneLens = RearCameraFacts(minimum: 1, maximum: 5, lenses: [Lens(start: 1)])

    @Test("The lens buttons are the zoom steps the phone has: 0.5, 1, 2, 4 and 8 on an iPhone 17 Pro, opening on 1")
    func lensesOfAnIPhone17Pro() {
        let zoom = CaptureZoom(Self.iPhone17Pro)
        #expect(zoom.lenses == [0.5, 1, 2, 4, 8])
        #expect(zoom.factor == 1)
        #expect(zoom.currentLens == 1)
    }

    @Test("A phone with fewer lenses has fewer buttons, and no more than it has")
    func fewerLenses() {
        #expect(CaptureZoom(Self.twoLenses).lenses == [0.5, 1, 2])
        #expect(CaptureZoom(Self.oneLens).lenses == [1])
        #expect(CaptureZoom(Self.oneLens).factor == 1)
        // A 13 Pro's shape: a telephoto at three times the wide, 12 MP sensors.
        let threeTimes = RearCameraFacts(minimum: 1, maximum: 30, lenses: [Lens(start: 1), Lens(start: 2), Lens(start: 6)], displayMultiplier: 0.5)
        #expect(CaptureZoom(threeTimes).lenses == [0.5, 1, 3])
        // A camera that says nothing of its lenses still has the one it opens on.
        #expect(CaptureZoom(RearCameraFacts(minimum: 1, maximum: 1, lenses: [])).lenses == [1])
        #expect(CaptureZoom.fixed.lenses == [1])
    }

    @Test("A lens's full-quality crop is a step only while that lens is still the one in use, and only within the camera's reach")
    func cropsPastTheNextLens() {
        // The wide's crop at 2× would land past the telephoto's start at 1.5×: the telephoto is the better picture there.
        let near = RearCameraFacts(minimum: 1, maximum: 10, lenses: [Lens(start: 1, fullQualityCrops: [2]), Lens(start: 1.5)])
        #expect(CaptureZoom(near).lenses == [1, 1.5])
        // A crop beyond what the camera can be set to is no step.
        let short = RearCameraFacts(minimum: 1, maximum: 1.5, lenses: [Lens(start: 1, fullQualityCrops: [2])])
        #expect(CaptureZoom(short).lenses == [1])
    }

    @Test("A step too close to another is no button: no 0.9 beside the 1, and the wide lens and the lens starts are the ones kept")
    func stepsTooClose() {
        // An ultra-wide whose sensor lists a crop just short of the wide's start: 1.8 of the camera's, 0.9 as a person reads it.
        var facts = Self.iPhone17Pro
        facts.lenses[0].fullQualityCrops = [1.8]
        #expect(CaptureZoom(facts).lenses == [0.5, 1, 2, 4, 8])
        // A lens that starts just short of the wide: the wide, where the camera opens, is the one kept.
        let nearWide = RearCameraFacts(minimum: 1, maximum: 60, lenses: [Lens(start: 1), Lens(start: 1.8), Lens(start: 2, fullQualityCrops: [2])], displayMultiplier: 0.5)
        #expect(CaptureZoom(nearWide).lenses == [0.5, 1, 2])
        #expect(CaptureZoom(nearWide).factor == 1)
        // A crop a little past a lens's start gives way to the start.
        let nearStart = RearCameraFacts(minimum: 1, maximum: 10, lenses: [Lens(start: 1, fullQualityCrops: [1.1, 2]), Lens(start: 3)])
        #expect(CaptureZoom(nearStart).lenses == [1, 2, 3])
    }

    @Test("A pinch runs from the widest lens to five times the last step, or as far as the camera goes, and no further")
    func range() {
        var zoom = CaptureZoom(Self.iPhone17Pro)
        #expect(zoom.range == 0.5...40)
        zoom.set(100)
        #expect(zoom.factor == 40)
        zoom.set(0.1)
        #expect(zoom.factor == 0.5)
        zoom.set(.nan)
        #expect(zoom.factor == 0.5)
        #expect(CaptureZoom(Self.oneLens).range == 1...5)
        #expect(CaptureZoom(Self.twoLenses).range == 0.5...10)
        #expect(CaptureZoom.fixed.range == 1...1)
    }

    @Test("Between two lenses the marked button is the one behind, and the camera is handed the factor in its own terms")
    func betweenLenses() {
        var zoom = CaptureZoom(Self.iPhone17Pro)
        zoom.set(2.6)
        #expect(zoom.currentLens == 2)
        #expect(zoom.deviceFactor == 5.2)
        zoom.set(0.7)
        #expect(zoom.currentLens == 0.5)
        zoom.set(8)
        #expect(zoom.currentLens == 8)
        #expect(zoom.deviceFactor == 16)
        zoom.set(31)
        #expect(zoom.currentLens == 8)
    }

    @Test("VoiceOver's swipe goes a lens at a time, and past the last lens doubles up to the end and halves back to it")
    func steps() {
        var zoom = CaptureZoom(Self.iPhone17Pro)
        #expect(zoom.stepped(in: true) == 2)
        #expect(zoom.stepped(in: false) == 0.5)
        zoom.set(2.6)
        #expect(zoom.stepped(in: true) == 4)
        #expect(zoom.stepped(in: false) == 2)
        zoom.set(8)
        #expect(zoom.stepped(in: true) == 16)
        #expect(zoom.stepped(in: false) == 4)
        zoom.set(32)
        #expect(zoom.stepped(in: true) == 40)
        #expect(zoom.stepped(in: false) == 16)
        zoom.set(40)
        #expect(zoom.stepped(in: true) == 40)
        zoom.set(12)
        #expect(zoom.stepped(in: false) == 8)
        zoom.set(0.5)
        #expect(zoom.stepped(in: false) == 0.5)
    }

    @Test("A factor reads as the phone's camera writes it, and VoiceOver hears it in words")
    func words() {
        #expect(CaptureZoom.text(0.5) == "0.5×")
        #expect(CaptureZoom.text(1) == "1×")
        #expect(CaptureZoom.text(2.64) == "2.6×")
        #expect(CaptureZoom.text(2.96) == "3×")
        #expect(CaptureZoom.text(9.96) == "10×")
        #expect(CaptureZoom.text(12.4) == "12×")
        #expect(CaptureZoom.text(40) == "40×")
        #expect(CaptureZoom.spoken(0.5) == "0.5 times")
        #expect(CaptureZoom.spoken(2.64) == "2.6 times")
        #expect(CaptureZoom.spoken(8) == "8 times")
    }
}
