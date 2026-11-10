import AVFoundation
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import BirdJournal

// Issue #187 (of #185): the capture camera's controls. The simulator has no camera, so the stand-in is the camera here: it
// reports the zoom it is set to and where focus is held, through the same seam (`CaptureCamera`) the phone's camera answers.
@Suite("Camera controls", .serialized)
@MainActor
struct CameraControlsTests {
    typealias Screens = ScreenAccessibilityTests

    @Test("The stand-in has an iPhone 17 Pro's lenses and reports the zoom it is set to, within what such a camera can do")
    func standInZoom() async {
        let camera = StandInCaptureCamera(.ready)
        #expect(camera.zoom == .fixed, "no lenses to speak of before it opens")
        await camera.start()
        #expect(camera.zoom.lenses == [0.5, 1, 2, 4, 8])
        #expect(camera.zoom.factor == 1)

        camera.setZoom(4, smoothly: true)
        #expect(camera.zoom.factor == 4)
        #expect(camera.zoom.currentLens == 4)
        camera.setZoom(2.6, smoothly: false)
        #expect(camera.zoom.factor == 2.6)
        #expect(camera.zoom.currentLens == 2)
        camera.setZoom(500, smoothly: false)
        #expect(camera.zoom.factor == 40)
    }

    @Test("A stand-in for a phone with one lens has one, and a camera that didn't open has nothing to zoom or focus")
    func otherCameras() async {
        let oneLens = StandInCaptureCamera(.ready, lenses: CaptureZoomTests.oneLens)
        await oneLens.start()
        #expect(oneLens.zoom.lenses == [1])

        let refused = StandInCaptureCamera(.denied)
        await refused.start()
        refused.setZoom(4, smoothly: true)
        refused.focus(at: UnitPoint(x: 0.5, y: 0.5))
        #expect(refused.zoom == .fixed)
        #expect(refused.focusPoint == nil)

        // For a screenshot: one that opens zoomed, with focus held.
        let staged = StandInCaptureCamera(.ready, opensAt: 2.6, focusedAt: UnitPoint(x: 0.3, y: 0.4))
        await staged.start()
        #expect(staged.zoom.factor == 2.6)
        #expect(staged.focusPoint == UnitPoint(x: 0.3, y: 0.4))
    }

    @Test("A tap holds focus and exposure where it landed; the shot gives them back to the camera and leaves the zoom alone")
    func focus() async throws {
        let camera = StandInCaptureCamera(.ready)
        await camera.start()
        #expect(camera.focusPoint == nil, "the camera focuses by itself until told where")

        camera.focus(at: UnitPoint(x: 0.25, y: 0.75))
        #expect(camera.focusPoint == UnitPoint(x: 0.25, y: 0.75))
        camera.focus(at: UnitPoint(x: 1.4, y: -0.2))
        #expect(camera.focusPoint == UnitPoint(x: 1, y: 0), "a tap is somewhere in the picture")

        camera.setZoom(4, smoothly: true)
        #expect(camera.focusPoint == UnitPoint(x: 1, y: 0), "zooming is not a shot")
        _ = try await camera.takePhoto()
        #expect(camera.focusPoint == nil, "continuous again after the shot")
        #expect(camera.zoom.factor == 4)
    }

    @Test("The flash never fires: the phone's camera asks for every photo with it off, and nothing can ask otherwise")
    func flash() {
        #expect(PhoneCaptureCamera.settingsForAPhoto().flashMode == .off)
    }

    // MARK: The screen, as VoiceOver finds it

    /// The camera screen over `camera`, in a window with app accessibility on, for as long as `body` runs. `elements` walks
    /// what VoiceOver reaches at that moment, top to bottom.
    static func onTheCameraScreen(
        _ camera: StandInCaptureCamera, harness: Screens.Harness, typeSize: DynamicTypeSize = .large, screen: CGSize = CGSize(width: 402, height: 874),
        _ body: (_ elements: () -> [NSObject]) async throws -> Void
    ) async throws {
        await harness.place.prepareForLaunch()
        CardFlipAccessibilityTests.enableAccessibility()
        let host = UIHostingController(rootView: harness.shared(CaptureCameraView(camera: camera, taken: { _ in }, close: {}), typeSize: typeSize))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(origin: .zero, size: screen)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        defer { window.isHidden = true }
        try await body { Self.elements(host.view) }
    }

    static func elements(_ object: Any) -> [NSObject] {
        guard let object = object as? NSObject, !object.accessibilityElementsHidden else { return [] }
        if object.isAccessibilityElement { return [object] }
        if let elements = object.accessibilityElements, !elements.isEmpty { return elements.flatMap(Self.elements) }
        let count = object.accessibilityElementCount()
        if count != NSNotFound, count > 0 { return (0..<count).compactMap { object.accessibilityElement(at: $0) }.flatMap(Self.elements) }
        if let view = object as? UIView { return view.subviews.flatMap(Self.elements) }
        return []
    }

    /// Walks again until `ready` holds, or five seconds pass: SwiftUI fills the tree some time after a change.
    static func settled(_ elements: () -> [NSObject], until ready: ([NSObject]) -> Bool) async throws -> [NSObject] {
        var found: [NSObject] = []
        for _ in 0..<50 {
            found = elements()
            if ready(found) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        return found
    }

    static func labels(_ elements: [NSObject]) -> [String] { elements.map { $0.accessibilityLabel ?? "" } }
    static func lensButtons(_ elements: [NSObject]) -> [NSObject] {
        elements.filter { $0.accessibilityTraits.contains(.button) && ($0.accessibilityLabel ?? "").hasSuffix(" times zoom") }
    }
    static func element(_ label: String, in elements: [NSObject]) -> NSObject? { elements.first { $0.accessibilityLabel == label } }

    @Test("The camera has the phone's lens buttons and no more, the one in use marked, under the viewfinder; and says the flash is off", arguments: Screens.sizes)
    func lensButtons(typeSize: DynamicTypeSize) async throws {
        let harness = try Screens.Harness()
        await harness.run.start()
        let camera = StandInCaptureCamera(.ready)
        try await Self.onTheCameraScreen(camera, harness: harness, typeSize: typeSize) { elements in
            let found = try await Self.settled(elements) { Self.lensButtons($0).count == 5 }
            let labels = Self.labels(found)
            Screens.expectClean(labels, screen: "Camera controls")
            #expect(Self.labels(Self.lensButtons(found)) == ["0.5 times zoom", "1 times zoom", "2 times zoom", "4 times zoom", "8 times zoom"], "\(labels)")
            #expect(Self.lensButtons(found).filter { $0.accessibilityTraits.contains(.selected) }.map(\.accessibilityLabel) == ["1 times zoom"], "only the lens in use is marked")

            let pill = try #require(labels.firstIndex { $0.hasPrefix("Still listening") }, "\(labels)")
            let flash = try #require(labels.firstIndex(of: "Flash off"), "\(labels)")
            let viewfinder = try #require(labels.firstIndex(of: "Viewfinder"), "\(labels)")
            let widest = try #require(labels.firstIndex(of: "0.5 times zoom"), "\(labels)")
            let shutter = try #require(labels.firstIndex(of: "Take photo"), "\(labels)")
            #expect(pill < flash && flash < viewfinder && viewfinder < widest && widest < shutter, "from the top down: \(labels)")
            #expect(found[flash].accessibilityTraits.contains(.button) == false, "nothing to press: it is always off")
        }
        await harness.run.stop()

        // A phone with one rear lens has one button; a camera that didn't open has none.
        try await Self.onTheCameraScreen(StandInCaptureCamera(.ready, lenses: CaptureZoomTests.oneLens), harness: harness, typeSize: typeSize) { elements in
            let found = try await Self.settled(elements) { !Self.lensButtons($0).isEmpty }
            #expect(Self.labels(Self.lensButtons(found)) == ["1 times zoom"], "\(Self.labels(found))")
        }
        try await Self.onTheCameraScreen(StandInCaptureCamera(.denied), harness: harness, typeSize: typeSize) { elements in
            let found = try await Self.settled(elements) { Self.labels($0).contains("Open Settings") }
            #expect(Self.lensButtons(found).isEmpty, "\(Self.labels(found))")
        }
    }

    @Test("A lens button zooms there and is then the marked one; between two lenses the one behind is marked and reads the factor")
    func aLensButtonZooms() async throws {
        let harness = try Screens.Harness()
        let camera = StandInCaptureCamera(.ready)
        try await Self.onTheCameraScreen(camera, harness: harness) { elements in
            var found = try await Self.settled(elements) { Self.lensButtons($0).count == 5 }
            let telephoto = try #require(Self.element("4 times zoom", in: found), "\(Self.labels(found))")
            #expect(telephoto.accessibilityActivate())
            #expect(camera.zoom.factor == 4)
            found = try await Self.settled(elements) { Self.element("4 times zoom", in: $0)?.accessibilityTraits.contains(.selected) == true }
            #expect(Self.lensButtons(found).filter { $0.accessibilityTraits.contains(.selected) }.map(\.accessibilityLabel) == ["4 times zoom"], "\(Self.labels(found))")
            #expect(Self.element("Viewfinder", in: found)?.accessibilityValue == "4 times zoom")

            // As a pinch leaves it: the factor is shown on the lens it has passed.
            camera.setZoom(2.6, smoothly: false)
            found = try await Self.settled(elements) { Self.element("2.6 times zoom", in: $0) != nil }
            #expect(Self.labels(Self.lensButtons(found)) == ["0.5 times zoom", "1 times zoom", "2.6 times zoom", "4 times zoom", "8 times zoom"], "\(Self.labels(found))")
            #expect(Self.element("2.6 times zoom", in: found)?.accessibilityTraits.contains(.selected) == true)
            #expect(Self.element("Viewfinder", in: found)?.accessibilityValue == "2.6 times zoom")
        }
    }

    @Test("VoiceOver zooms on the viewfinder: a swipe up for the next lens, a swipe down for the one before")
    func voiceOverZooms() async throws {
        let harness = try Screens.Harness()
        let camera = StandInCaptureCamera(.ready)
        try await Self.onTheCameraScreen(camera, harness: harness) { elements in
            let found = try await Self.settled(elements) { Self.element("Viewfinder", in: $0)?.accessibilityValue == "1 times zoom" }
            let viewfinder = try #require(Self.element("Viewfinder", in: found), "\(Self.labels(found))")
            #expect(viewfinder.accessibilityValue == "1 times zoom")
            #expect(viewfinder.accessibilityTraits.contains(.adjustable), "VoiceOver says it can be adjusted")

            viewfinder.accessibilityIncrement()
            #expect(camera.zoom.factor == 2)
            let zoomed = try await Self.settled(elements) { Self.element("Viewfinder", in: $0)?.accessibilityValue == "2 times zoom" }
            let again = try #require(Self.element("Viewfinder", in: zoomed))
            #expect(again.accessibilityValue == "2 times zoom")
            again.accessibilityDecrement()
            again.accessibilityDecrement()
            #expect(camera.zoom.factor == 0.5)
        }
    }

    @Test("While focus is held where the birder tapped the viewfinder says so, and stops saying so after the shot")
    func focusIsSaid() async throws {
        let harness = try Screens.Harness()
        let camera = StandInCaptureCamera(.ready)
        try await Self.onTheCameraScreen(camera, harness: harness) { elements in
            _ = try await Self.settled(elements) { Self.element("Viewfinder", in: $0)?.accessibilityValue == "1 times zoom" }
            camera.focus(at: UnitPoint(x: 0.3, y: 0.4))
            var found = try await Self.settled(elements) { Self.element("Viewfinder", in: $0)?.accessibilityValue != "1 times zoom" }
            #expect(Self.element("Viewfinder", in: found)?.accessibilityValue == "1 times zoom, focus set")
            _ = try await camera.takePhoto()
            found = try await Self.settled(elements) { Self.element("Viewfinder", in: $0)?.accessibilityValue == "1 times zoom" }
            #expect(Self.element("Viewfinder", in: found)?.accessibilityValue == "1 times zoom")
        }
    }

    @Test("With the phone on its side every lens button is still whole: full size, on the screen, side by side and clear of the shutter")
    func onItsSide() async throws {
        let harness = try Screens.Harness()
        let screen = CGSize(width: 874, height: 402)
        try await Self.onTheCameraScreen(StandInCaptureCamera(.ready), harness: harness, screen: screen) { elements in
            let found = try await Self.settled(elements) { Self.lensButtons($0).count == 5 }
            let frames = Self.lensButtons(found).map(\.accessibilityFrame)
            let shutter = try #require(Self.element("Take photo", in: found), "\(Self.labels(found))").accessibilityFrame
            #expect(frames.count == 5)
            for frame in frames {
                // 44 points, give or take what a float loses on the way to the screen.
                #expect(frame.width > 43.9 && frame.height > 43.9, "\(frame)")
                #expect(CGRect(origin: .zero, size: screen).contains(frame), "\(frame)")
                #expect(!frame.intersects(shutter), "\(frame) against the shutter's \(shutter)")
            }
            #expect(zip(frames, frames.dropFirst()).allSatisfy { $0.maxX <= $1.minX + 0.5 }, "\(frames)")
        }
    }
}
