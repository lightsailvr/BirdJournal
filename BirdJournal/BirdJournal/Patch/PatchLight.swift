import CoreMotion
import Foundation
import Observation
import OSLog
import QuartzCore
import simd
import UIKit

/// Where a patch's light is (issue #134, guide page 13), from gravity in the device's frame: pure, so its feel is tested
/// without a phone. The first reading is "as held" and puts the light at its resting place, upper-left. Tilting from
/// there moves the light as a lamp overhead would seem to move, smoothed, up to 35° of tilt. Past 35° the "as held"
/// reading is dragged along, so the first degree back is a degree of light. Below `stillness` nothing is published: a
/// still phone's sensor noise never moves the light, and the light stops when the phone does.
///
/// Gravity rather than the attitude's Euler angles: they're unstable when the phone is held upright, and turning on the
/// spot (yaw) shouldn't move a lamp overhead.
nonisolated struct PatchLightModel: Sendable {
    /// Upper-left, in the screen's axes (y runs down), where z is 1: where the light rests, and stays under Reduce Motion.
    static let rest = SIMD2<Double>(-0.46, -0.62)
    /// How far the full 35° moves it from `rest`: far enough that a hand's ordinary 10° shows (`PatchLightPixelTests`).
    static let reach = 1.1
    static let clampDegrees = 35.0
    /// Each reading's share of the smoothed tilt: about 100 ms to follow at 60 Hz.
    static let smoothing = 0.16
    /// The tilt in degrees the smoothed value must differ from the published one by.
    static let stillness = 0.12

    private(set) var direction = rest
    private var held: SIMD3<Double>?
    private var smoothed = SIMD2<Double>.zero
    private var published = SIMD2<Double>.zero

    /// Takes one reading of gravity; true when the light moved.
    @discardableResult
    mutating func update(gravity: SIMD3<Double>) -> Bool {
        let current = simd_normalize(gravity)
        guard let reference = held else {
            held = current
            return false
        }
        let tilt = clampedTilt(from: reference, to: current)
        smoothed += (tilt - smoothed) * Self.smoothing
        guard simd_length(smoothed - published) >= Self.stillness else { return false }
        published = smoothed
        direction = Self.rest + published / Self.clampDegrees * Self.reach
        return true
    }

    /// Forgets how the phone was held: the next reading starts again from `rest`.
    mutating func reset() {
        self = PatchLightModel()
    }

    /// The tilt in degrees, as the light's change in the screen's axes, dragging `held` along past the clamp.
    private mutating func clampedTilt(from reference: SIMD3<Double>, to current: SIMD3<Double>) -> SIMD2<Double> {
        let axis = simd_cross(reference, current)
        let length = simd_length(axis)
        guard length > 1e-9 else { return .zero }
        let degrees = atan2(length, simd_dot(reference, current)) * 180 / .pi
        let unit = axis / length
        if degrees > Self.clampDegrees {
            held = simd_quatd(angle: -Self.clampDegrees * .pi / 180, axis: unit).act(current)
        }
        // Rotating gravity about the device's y lowers the right edge, which moves a lamp overhead left; about x, raises
        // the top edge, which moves it up the screen.
        return SIMD2(unit.y, unit.x) * min(degrees, Self.clampDegrees)
    }
}

extension PatchLightModel {
    /// Gravity in the axes of the screen as it's showing, so "upper-left" stays upper-left when the phone turns sideways.
    /// Core Motion's axes are the portrait device's: x to its right edge, y to its top.
    static func gravity(_ device: SIMD3<Double>, showing orientation: UIInterfaceOrientation) -> SIMD3<Double> {
        switch orientation {
        // The device's top points left of the screen.
        case .landscapeRight: SIMD3(-device.y, device.x, device.z)
        // The device's top points right of the screen.
        case .landscapeLeft: SIMD3(device.y, -device.x, device.z)
        case .portraitUpsideDown: SIMD3(-device.x, -device.y, device.z)
        default: device
        }
    }
}

/// The one light every patch on screen is lit by (guide page 18: one light uniform): the phone only has one attitude.
/// Runs Core Motion while a lit surface holds it.
@MainActor @Observable
final class PatchLight {
    static let shared = PatchLight()

    private(set) var direction = PatchLightModel.rest

    @ObservationIgnored private var model = PatchLightModel()
    @ObservationIgnored private var holders = 0
    @ObservationIgnored private var orientation = UIInterfaceOrientation.portrait
    @ObservationIgnored private let motion = CMMotionManager()
    #if DEBUG
    @ObservationIgnored private var sweep: PatchLightSweep?
    #endif

    init() {
        #if DEBUG
        // Issue #134's screenshots: `-patchLight "x,y"` puts the light somewhere, as a tilt would.
        // A launch argument can't start with a minus, so "l0.5,u0.6" reads left and up as well as "0.5,-0.6".
        let parts = UserDefaults.standard.string(forKey: "patchLight")?.split(separator: ",").compactMap { part in
            part.first.map { "lu".contains($0) } == true ? Double(part.dropFirst()).map { -$0 } : Double(part)
        } ?? []
        if parts.count == 2 { direction = SIMD2(parts[0], parts[1]) }
        // The board's frame budget (guide page 18): `-patchLightSweep YES` moves the light as a steady tilt would and logs
        // the frame times, on the simulator or a phone.
        if UserDefaults.standard.bool(forKey: "patchLightSweep") {
            sweep = PatchLightSweep { [weak self] in self?.direction = $0 }
        }
        #endif
    }

    /// What a surface draws with: under Reduce Motion the light stays upper-left.
    nonisolated static func shown(_ direction: SIMD2<Double>, reduceMotion: Bool) -> SIMD2<Double> {
        reduceMotion ? PatchLightModel.rest : direction
    }

    /// A lit surface came on screen: starts the motion updates for the first one.
    func hold() {
        holders += 1
        guard holders == 1, motion.isDeviceMotionAvailable else { return }
        restart()
        motion.deviceMotionUpdateInterval = 1.0 / 60
        motion.startDeviceMotionUpdates(to: .main) { [weak self] reading, _ in
            guard let gravity = reading?.gravity else { return }
            let vector = SIMD3(gravity.x, gravity.y, gravity.z)
            MainActor.assumeIsolated { self?.read(device: vector) }
        }
    }

    /// A lit surface left the screen: stops the motion updates after the last one.
    func release() {
        holders = max(holders - 1, 0)
        if holders == 0 { motion.stopDeviceMotionUpdates() }
    }

    /// A new surface starts from "as held": the light rests upper-left, however it was left the last time.
    func restart() {
        model.reset()
        direction = model.direction
    }

    /// One reading from the device. A turn of the screen starts again from upper-left: the old "as held" was in other axes.
    private func read(device gravity: SIMD3<Double>) {
        let showing = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.effectiveGeometry.interfaceOrientation ?? .portrait
        if showing != orientation {
            orientation = showing
            restart()
        }
        take(PatchLightModel.gravity(gravity, showing: showing))
    }

    func take(_ gravity: SIMD3<Double>) {
        if model.update(gravity: gravity) { direction = model.direction }
    }
}

#if DEBUG
/// Circles the light around where it rests at the display's rate and logs how long frames took, every two seconds.
@MainActor
private final class PatchLightSweep: NSObject {
    private static let log = Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "patch-light")
    private let move: (SIMD2<Double>) -> Void
    private var link: CADisplayLink?
    private var start: CFTimeInterval?
    private var last: CFTimeInterval?
    private var durations: [CFTimeInterval] = []

    init(move: @escaping (SIMD2<Double>) -> Void) {
        self.move = move
        super.init()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let begun = start ?? now
        start = begun
        let angle = (now - begun) * 1.5
        move(PatchLightModel.rest + SIMD2(cos(angle), sin(angle)) * PatchLightModel.reach)
        if let last { durations.append(now - last) }
        last = now
        guard durations.count >= 240 else { return }
        let sorted = durations.sorted()
        let budget = link.targetTimestamp - link.timestamp
        let over = sorted.filter { $0 > budget * 1.5 }.count
        let (median, p95, worst) = (sorted[sorted.count / 2] * 1000, sorted[sorted.count * 95 / 100] * 1000, (sorted.last ?? 0) * 1000)
        Self.log.notice("frames \(sorted.count) median \(median, format: .fixed(precision: 1)) ms p95 \(p95, format: .fixed(precision: 1)) ms worst \(worst, format: .fixed(precision: 1)) ms; over 1.5x budget: \(over)")
        durations.removeAll(keepingCapacity: true)
    }
}
#endif
