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
}
