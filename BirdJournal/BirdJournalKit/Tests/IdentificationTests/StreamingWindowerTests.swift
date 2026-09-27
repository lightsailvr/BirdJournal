import Testing
@testable import Identification

// Windows are 4 samples with a 2-sample hop here so the arithmetic is readable; production uses WindowPlanner's
// 3 s / 1.5 s defaults at 32 kHz.
@Suite("StreamingWindower")
struct StreamingWindowerTests {
    private let planner = WindowPlanner(sampleRate: 4, windowDuration: 1, hopDuration: 0.5)

    @Test("windows appear as soon as enough samples have arrived, across chunk boundaries")
    func windowsAcrossChunks() {
        var windower = StreamingWindower(planner: planner)

        #expect(windower.append([0, 1, 2]).isEmpty)
        #expect(windower.append([3, 4]) == [AudioWindow(start: 0, samples: [0, 1, 2, 3])])
        #expect(windower.append([5, 6, 7]) == [
            AudioWindow(start: 2, samples: [2, 3, 4, 5]),
            AudioWindow(start: 4, samples: [4, 5, 6, 7]),
        ])
        #expect(windower.samplesSeen == 8)
    }

    @Test("one large chunk yields every complete window and keeps the partial tail for later")
    func largeChunk() {
        var windower = StreamingWindower(planner: planner)

        let windows = windower.append([0, 1, 2, 3, 4, 5, 6])

        #expect(windows.map(\.start) == [0, 2])
        #expect(windower.append([7]) == [AudioWindow(start: 4, samples: [4, 5, 6, 7])])
    }

    @Test("empty chunks are tolerated")
    func emptyChunk() {
        var windower = StreamingWindower(planner: planner)
        #expect(windower.append([]).isEmpty)
        #expect(windower.samplesSeen == 0)
    }
}
