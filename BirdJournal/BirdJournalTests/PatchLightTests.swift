import Accelerate
import Observation
import Foundation
import Pack
import simd
import SwiftUI
import Testing
import UIKit
@testable import BirdJournal

// Issue #134 (guide page 13): the patch's light comes from the phone's tilt, smoothed and clamped to ±35°. It moves only
// when the phone does: no idle glints, and it comes to rest when the phone does.
@Suite("Patch light")
struct PatchLightTests {
    /// Gravity in the device's frame, with the phone flat, then its right edge lowered and its top edge raised.
    static func gravity(rightEdgeDown: Double = 0, topEdgeUp: Double = 0) -> SIMD3<Double> {
        let (right, top) = (rightEdgeDown * .pi / 180, topEdgeUp * .pi / 180)
        return simd_normalize(SIMD3(sin(right), -sin(top), -cos(right) * cos(top)))
    }

    /// A model held at `first`, then fed `gravity` for a second and more at 60 Hz, long enough to settle.
    static func settled(at gravity: SIMD3<Double>, from first: SIMD3<Double> = PatchLightTests.gravity()) -> PatchLightModel {
        var model = PatchLightModel()
        model.update(gravity: first)
        for _ in 0..<120 { model.update(gravity: gravity) }
        return model
    }

    @Test("a surface holds the light while on screen, and lets it go with the phone locked: a run's rows stay up for a whole walk (issue #150)")
    func theLightStopsWithTheScene() {
        #expect(PatchLight.isWanted(isOnScreen: true, phase: .active))
        #expect(PatchLight.isWanted(isOnScreen: true, phase: .inactive), "a passing sheet or Control Center doesn't restart it")
        #expect(!PatchLight.isWanted(isOnScreen: true, phase: .background))
        #expect(!PatchLight.isWanted(isOnScreen: false, phase: .active))
    }

    @Test("the light starts upper-left, however the phone is held")
    func startsUpperLeft() {
        for held in [Self.gravity(), Self.gravity(topEdgeUp: 70), Self.gravity(rightEdgeDown: 20, topEdgeUp: 45)] {
            var model = PatchLightModel()
            model.update(gravity: held)
            #expect(model.direction == PatchLightModel.rest)
        }
        #expect(PatchLightModel.rest.x < 0, "left")
        #expect(PatchLightModel.rest.y < 0, "up: the screen's y runs down")
    }

    @Test("lowering the right edge moves the light left; raising the top edge moves it up, as a lamp overhead would")
    func followsTheTilt() {
        let right = Self.settled(at: Self.gravity(rightEdgeDown: 20)).direction
        #expect(right.x < PatchLightModel.rest.x - 0.1)
        #expect(abs(right.y - PatchLightModel.rest.y) < 0.02)

        let left = Self.settled(at: Self.gravity(rightEdgeDown: -20)).direction
        #expect(left.x > PatchLightModel.rest.x + 0.1)

        let top = Self.settled(at: Self.gravity(topEdgeUp: 20)).direction
        #expect(top.y < PatchLightModel.rest.y - 0.1)
        #expect(abs(top.x - PatchLightModel.rest.x) < 0.02)
    }

    @Test("the tilt is clamped to 35°")
    func clamped() {
        let limit = Self.settled(at: Self.gravity(rightEdgeDown: 35)).direction
        let past = Self.settled(at: Self.gravity(rightEdgeDown: 80)).direction
        #expect(abs(limit.x - past.x) < 0.02)
        #expect(abs(limit.x - (PatchLightModel.rest.x - PatchLightModel.reach)) < 0.02, "the full reach at the limit")
    }

    @Test("past the clamp, coming back moves the light at once")
    func comesBackFromTheClamp() {
        var model = Self.settled(at: Self.gravity(rightEdgeDown: 80))
        let atLimit = model.direction
        for _ in 0..<120 { model.update(gravity: Self.gravity(rightEdgeDown: 70)) }
        #expect(model.direction.x > atLimit.x + 0.1, "ten degrees back is ten degrees of light, not nothing until 35°")
    }

    @Test("a sudden tilt is smoothed, not a jump, and arrives within about a second")
    func smoothed() {
        var model = PatchLightModel()
        model.update(gravity: Self.gravity())
        let target = Self.settled(at: Self.gravity(rightEdgeDown: 30)).direction
        model.update(gravity: Self.gravity(rightEdgeDown: 30))
        #expect(abs(model.direction.x - PatchLightModel.rest.x) < abs(target.x - PatchLightModel.rest.x) / 3, "the first sample moves it only part way")
        for _ in 0..<60 { model.update(gravity: Self.gravity(rightEdgeDown: 30)) }
        #expect(abs(model.direction.x - target.x) < 0.02)
    }

    @Test("a still phone's sensor noise never moves the light")
    func noIdleGlints() {
        var model = PatchLightModel()
        let held = Self.gravity(rightEdgeDown: 10, topEdgeUp: 45)
        model.update(gravity: held)
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<600 {
            let noisy = Self.gravity(rightEdgeDown: 10 + .random(in: -0.04...0.04, using: &generator), topEdgeUp: 45 + .random(in: -0.04...0.04, using: &generator))
            #expect(model.update(gravity: noisy) == false, "the light moved with the phone still")
        }
        #expect(model.direction == PatchLightModel.rest)
    }

    @Test("the light stops when the phone stops")
    func stopsWithThePhone() {
        var model = PatchLightModel()
        model.update(gravity: Self.gravity())
        for step in 1...30 { model.update(gravity: Self.gravity(rightEdgeDown: Double(step))) }
        var moved = 0
        for _ in 0..<120 where model.update(gravity: Self.gravity(rightEdgeDown: 30)) { moved += 1 }
        #expect(moved > 0, "it eases to a stop")
        let stopped = model.direction
        for _ in 0..<120 { #expect(model.update(gravity: Self.gravity(rightEdgeDown: 30)) == false) }
        #expect(model.direction == stopped)
    }

    @Test("the shared light follows its readings, and a new surface starts again from upper-left, not where it was left")
    @MainActor
    func startsAgain() {
        let light = PatchLight()
        light.take(Self.gravity())
        for _ in 0..<120 { light.take(Self.gravity(rightEdgeDown: 30)) }
        #expect(light.direction.x < PatchLightModel.rest.x - 0.1)
        light.restart()
        #expect(light.direction == PatchLightModel.rest)
        // The phone is still tilted, and that's the new "as held": no jump on the next reading.
        light.take(Self.gravity(rightEdgeDown: 30))
        #expect(light.direction == PatchLightModel.rest)
    }

    @Test("sideways, gravity is read in the screen's axes, so the edge you lower is the one on the screen")
    func sideways() {
        // Flat, with the device's bottom edge lowered: gravity runs toward it, y negative in the device's axes.
        let bottomDown = SIMD3<Double>(0, -0.5, -0.87)
        // Home on the right: the device's bottom is the screen's right.
        #expect(PatchLightModel.gravity(bottomDown, showing: .landscapeRight).x > 0)
        #expect(PatchLightModel.gravity(bottomDown, showing: .landscapeRight).y == 0)
        // Home on the left: the device's bottom is the screen's left.
        #expect(PatchLightModel.gravity(bottomDown, showing: .landscapeLeft).x < 0)
        #expect(PatchLightModel.gravity(bottomDown, showing: .portrait) == bottomDown)
        #expect(PatchLightModel.gravity(bottomDown, showing: .portrait).z == PatchLightModel.gravity(bottomDown, showing: .landscapeLeft).z)
    }

    @Test("Reduce Motion fixes the light upper-left whatever the phone does")
    func reduceMotion() {
        #expect(PatchLight.shown(PatchLightModel.rest + .init(0.4, 0.4), reduceMotion: true) == PatchLightModel.rest)
        #expect(PatchLight.shown(.init(0.2, 0.1), reduceMotion: false) == .init(0.2, 0.1))
    }
}

// Issue #134 (guide page 10): the flip takes about 600 ms. Issue #176: under Reduce Motion the outgoing face fades right out
// over the first half before the incoming one comes up over the second, so the two never show at once.
@Suite("Patch flip timing")
struct PatchFlipTimingTests {
    @Test("about 600 ms; Reduce Motion fades one face out, then the other in, without turning")
    func fadesInTurn() {
        #expect(CardFlip.duration == 0.6)
        #expect(CardFlip.animation(reduceMotion: false) != nil)
        #expect(CardFlip.animation(reduceMotion: true) != nil, "a fade, not a jump")
        for angle in stride(from: 0.0, through: 180, by: 15) {
            let front = CardFlip.face(isBack: false, angle: angle, rotates: false)
            let back = CardFlip.face(isBack: true, angle: angle, rotates: false)
            let progress = angle / 180
            #expect(front.degrees == 0 && back.degrees == 0)
            #expect(abs(front.opacity - max(0, 1 - 2 * progress)) < 0.0001, "angle \(angle)")
            #expect(abs(back.opacity - max(0, 2 * progress - 1)) < 0.0001, "angle \(angle)")
        }
        #expect(CardFlip.face(isBack: false, angle: 0, rotates: false).opacity == 1)
        #expect(CardFlip.face(isBack: true, angle: 180, rotates: false).opacity == 1)
    }
}

// The maintainer's phone (issue #134): the light followed the tilt in numbers, and nothing visibly changed on screen. So
// this goes from gravity to pixels: a hand's ordinary tilt has to change what the patch looks like.
@Suite("Patch light on screen", .serialized)
@MainActor
struct PatchLightPixelTests {
    /// How far apart two renders are, as the mean change per colour channel out of 255, over the patch.
    /// vDSP, in pieces: a Swift loop over a render's bytes held the main actor for seconds in a debug build, and every other
    /// test on it that waits by the clock timed out.
    static func meanChange(_ first: [UInt8], _ second: [UInt8]) -> Double {
        var total = 0.0
        let piece = 1 << 20
        for start in stride(from: 0, to: min(first.count, second.count), by: piece) {
            let end = min(start + piece, first.count, second.count)
            let a = vDSP.integerToFloatingPoint(first[start..<end], floatingPointType: Float.self)
            let b = vDSP.integerToFloatingPoint(second[start..<end], floatingPointType: Float.self)
            total += Double(vDSP.sum(vDSP.absolute(vDSP.subtract(a, b))))
        }
        return total / Double(max(first.count, 1))
    }

    static func pixels(of view: UIView) -> [UInt8] {
        let size = view.bounds.size
        let renderer = UIGraphicsImageRenderer(size: size, format: { let format = UIGraphicsImageRendererFormat(); format.scale = 1; return format }())
        let image = renderer.image { _ in view.drawHierarchy(in: view.bounds, afterScreenUpdates: true) }
        guard let cg = image.cgImage else { return [] }
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = CGContext(data: &bytes, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return bytes
    }

    /// A patch's blank, its painting arriving: what `PatchArtState` going from being sewn to painted does on screen.
    @MainActor @Observable
    final class Arriving {
        var art: PatchArt?
    }

    @Test("a blank being sewn fills in with the painting when it arrives")
    func beingSewnFillsIn() async throws {
        let pack = try SpeciesPack.bundled()
        let patch = try #require(pack.species(scientificName: "Haemorhous mexicanus")?.patch)
        let art = PatchArt(colour: pack.patchURL(for: patch), layers: pack.patchLayersURL(for: patch), ground: patch.ground)
        let arriving = Arriving()

        struct Slot: View {
            let arriving: Arriving
            var body: some View {
                PatchView(state: arriving.art.map(PatchArtState.painted) ?? .beingSewn, edition: PatchEdition.of(setID: "us-ca-la"), size: .full, tag: "House Finch")
                    .frame(width: 300, height: 300)
                    .background(Color.black)
            }
        }
        let host = UIHostingController(rootView: Slot(arriving: arriving))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = try UIWindow(windowScene: #require(scene))
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }

        try await Task.sleep(for: .milliseconds(400))
        let blank = Self.pixels(of: host.view)
        arriving.art = art
        var filled = blank
        for _ in 0..<40 where Self.meanChange(blank, filled) < 5 {
            try await Task.sleep(for: .milliseconds(250))
            filled = Self.pixels(of: host.view)
        }
        #expect(Self.meanChange(blank, filled) >= 5, "the blank stayed: \(Self.meanChange(blank, filled))")
    }

    @Test("a painting that won't decode shows the same blank and paper tag as one that isn't there")
    func unreadablePaintingIsTagged() async throws {
        func render(_ art: PatchArt?) async throws -> [UInt8] {
            let host = UIHostingController(rootView: PatchView(art: art, edition: PatchEdition.of(setID: "us-ca-la"), size: .full, tag: "House Finch").frame(width: 300, height: 300).background(Color.black))
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            let window = try UIWindow(windowScene: #require(scene))
            window.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
            window.rootViewController = host
            window.isHidden = false
            defer { window.isHidden = true }
            try await Task.sleep(for: .seconds(1))
            return Self.pixels(of: host.view)
        }
        let missing = URL(filePath: "/nowhere/patch-\(UUID().uuidString).avif")
        let unreadable = try await render(PatchArt(colour: missing, layers: missing, ground: "#C4A068"))
        let tagged = try await render(nil)
        #expect(tagged.contains { $0 > 0 }, "nothing rendered")
        #expect(Self.meanChange(unreadable, tagged) < 0.01, "they differ by \(Self.meanChange(unreadable, tagged))")
    }

    /// Here because it moves `PatchLight.shared`: this suite is serialized, and the global must not move under the test below.
    @Test("a tilt never reaches the share image, whose light is fixed (#136)")
    func theShareImageIgnoresATilt() async throws {
        let (facts, loaded) = try await ShareCardTests.bundledPatch()
        let image = PatchShareImage(facts: facts, edition: ShareCardTests.la, loaded: loaded)
        let light = PatchLight.shared
        light.restart()
        defer { light.restart() }
        let before = try ShareCardTests.rgba(try #require(CardExport.render(image, scale: 2)).image)
        // The first reading is "as held"; the tilt is from there.
        light.take(PatchLightTests.gravity())
        for _ in 0..<120 { light.take(PatchLightTests.gravity(rightEdgeDown: 30, topEdgeUp: 20)) }
        #expect(light.direction != PatchLightModel.rest, "the phone's light did move")
        let after = try ShareCardTests.rgba(try #require(CardExport.render(image, scale: 2)).image)
        #expect(Self.meanChange(before.bytes, after.bytes) == 0)
    }

    @Test("a ten-degree tilt visibly changes the lit patch, whichever way, and a still phone changes nothing")
    func tenDegrees() async throws {
        let pack = try SpeciesPack.bundled()
        let patch = try #require(pack.species(scientificName: "Haemorhous mexicanus")?.patch)
        let art = PatchArt(colour: pack.patchURL(for: patch), layers: pack.patchLayersURL(for: patch), ground: patch.ground)
        _ = await PatchTextures.load(art, size: .full)

        let host = UIHostingController(rootView: PatchView(art: art, edition: PatchEdition.of(setID: "us-ca-la"), size: .full).frame(width: 300, height: 300).background(Color.black))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = try UIWindow(windowScene: #require(scene))
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; PatchLight.shared.restart() }

        let light = PatchLight.shared
        func settle(rightEdgeDown: Double = 0, topEdgeUp: Double = 0) async throws -> [UInt8] {
            for _ in 0..<120 { light.take(PatchLightTests.gravity(rightEdgeDown: rightEdgeDown, topEdgeUp: topEdgeUp)) }
            try await Task.sleep(for: .milliseconds(500))
            return Self.pixels(of: host.view)
        }

        light.restart()
        let rest = try await settle()
        let still = try await settle()
        #expect(Self.meanChange(rest, still) < 0.1, "a still phone changes nothing")

        let measured = [
            ("right edge down", try await settle(rightEdgeDown: 10)),
            ("right edge up", try await settle(rightEdgeDown: -10)),
            ("top edge up", try await settle(topEdgeUp: 10)),
            ("top edge down", try await settle(topEdgeUp: -10)),
        ].map { ($0.0, Self.meanChange(rest, $0.1)) }
        print("patch light change at 10 degrees:", measured)
        for (tilt, change) in measured {
            #expect(change >= 3, "\(tilt) by 10° changed the patch by only \(change) of 255 per channel")
        }
    }
}
