import Foundation
import Identification
import Testing

// Issue #5: per-window inference stays under 150 ms on an iPhone 17 Pro. Package tests are tool-hosted and cannot
// run on a device, so this app-hosted test times the bundled acoustic model where it matters. On the simulator
// the numbers are informative only.
@Suite("Inference budget")
struct InferenceBudgetTests {
    @Test("a 3 s window scores within the 150 ms budget after one warm-up window")
    func windowWithinBudget() throws {
        let model = try ONNXBirdModel.bundled()
        var state: UInt64 = 20_260_926
        func noiseWindow() -> [Float] {
            (0..<96_000).map { _ in
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return Float(Int64(bitPattern: state) >> 40) / Float(1 << 23) * 0.1
            }
        }
        let clock = ContinuousClock()

        _ = try model.scores(for: noiseWindow())  // warm-up: first run pays for lazy runtime setup
        var timings: [Duration] = []
        for _ in 0..<5 {
            let window = noiseWindow()
            let began = clock.now
            _ = try model.scores(for: window)
            timings.append(clock.now - began)
        }

        let slowest = timings.max()!
        print("inference budget: windows \(timings.map { $0.formatted(.units(allowed: [.milliseconds])) }), slowest \(slowest.formatted(.units(allowed: [.milliseconds])))")
        #if !targetEnvironment(simulator)
        #expect(slowest <= .milliseconds(150), "slowest window \(slowest) exceeds the 150 ms budget")
        #endif
    }
}
