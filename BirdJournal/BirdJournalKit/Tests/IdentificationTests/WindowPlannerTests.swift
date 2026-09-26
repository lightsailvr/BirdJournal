import Testing
import OnnxRuntimeBindings
@testable import Identification

@Suite("WindowPlanner")
struct WindowPlannerTests {
    // 3 s windows with 1.5 s overlap at the model rate (DECISIONS.md, "Audio and identification").
    @Test("six seconds at 32 kHz yield three overlapping windows")
    func sixSecondsAtModelRate() {
        let planner = WindowPlanner()
        let sixSeconds = 6 * 32_000

        let windows = planner.windows(forSampleCount: sixSeconds)

        #expect(windows == [
            0..<96_000,
            48_000..<144_000,
            96_000..<192_000,
        ])
    }

    @Test("fewer samples than one window yield no windows")
    func tooShort() {
        let planner = WindowPlanner()
        #expect(planner.windows(forSampleCount: 95_999).isEmpty)
    }

    @Test("a trailing partial window is dropped")
    func partialTailDropped() {
        let planner = WindowPlanner()
        // 4 s: window at 0 s fits, window at 1.5 s would end at 4.5 s and is dropped.
        #expect(planner.windows(forSampleCount: 4 * 32_000) == [0..<96_000])
    }
}

@Suite("ONNX Runtime")
struct ONNXRuntimeLinkTests {
    @Test("the runtime environment can be created on this platform")
    func environmentCreates() throws {
        let env = try ORTEnv(loggingLevel: .warning)
        _ = env
    }
}
