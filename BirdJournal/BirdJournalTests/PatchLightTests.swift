import Foundation
import simd
import Testing
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

    @Test("Reduce Motion fixes the light upper-left whatever the phone does")
    func reduceMotion() {
        #expect(PatchLight.shown(PatchLightModel.rest + .init(0.4, 0.4), reduceMotion: true) == PatchLightModel.rest)
        #expect(PatchLight.shown(.init(0.2, 0.1), reduceMotion: false) == .init(0.2, 0.1))
    }
}

// Issue #134 (guide page 10): the flip takes about 600 ms; Reduce Motion cross-fades.
@Suite("Patch flip timing")
struct PatchFlipTimingTests {
    @Test("about 600 ms; Reduce Motion cross-fades without turning, the two faces' opacities adding to one")
    func crossFade() {
        #expect(CardFlip.duration == 0.6)
        #expect(CardFlip.animation(reduceMotion: false) != nil)
        #expect(CardFlip.animation(reduceMotion: true) != nil, "a fade, not a jump")
        for angle in stride(from: 0.0, through: 180, by: 15) {
            let front = CardFlip.face(isBack: false, angle: angle, rotates: false)
            let back = CardFlip.face(isBack: true, angle: angle, rotates: false)
            #expect(front.degrees == 0 && back.degrees == 0)
            #expect(abs(front.opacity + back.opacity - 1) < 0.0001, "angle \(angle)")
        }
        #expect(CardFlip.face(isBack: false, angle: 0, rotates: false).opacity == 1)
        #expect(CardFlip.face(isBack: true, angle: 180, rotates: false).opacity == 1)
    }
}
