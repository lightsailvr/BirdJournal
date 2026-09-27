/// One analysis window cut from the resampled session audio.
public struct AudioWindow: Sendable, Equatable {
    /// Index of the first sample, counted from the start of the session at the model rate.
    public let start: Int
    public let samples: [Float]

    public init(start: Int, samples: [Float]) {
        self.start = start
        self.samples = samples
    }
}

/// Accumulates model-rate samples as they arrive and hands out complete windows on the `WindowPlanner` grid.
/// A trailing partial window waits for more audio and is dropped if the stream ends first.
public struct StreamingWindower: Sendable {
    public let planner: WindowPlanner

    private var buffer: [Float] = []
    /// Session sample index of `buffer[0]`.
    private var bufferStart = 0

    public init(planner: WindowPlanner = WindowPlanner()) {
        self.planner = planner
    }

    /// Samples appended so far, at the model rate.
    public var samplesSeen: Int { bufferStart + buffer.count }

    /// Appends samples and returns every window that became complete, in order.
    public mutating func append(_ samples: [Float]) -> [AudioWindow] {
        buffer.append(contentsOf: samples)
        var windows: [AudioWindow] = []
        while buffer.count >= planner.samplesPerWindow {
            windows.append(AudioWindow(start: bufferStart, samples: Array(buffer[..<planner.samplesPerWindow])))
            buffer.removeFirst(planner.samplesPerHop)
            bufferStart += planner.samplesPerHop
        }
        return windows
    }
}
