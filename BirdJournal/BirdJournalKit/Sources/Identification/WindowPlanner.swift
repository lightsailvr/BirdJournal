/// Slices a mono sample buffer into fixed-length analysis windows for the acoustic model.
///
/// Defaults follow DECISIONS.md: 3 s windows with 1.5 s overlap at BirdNET+ V3.0's 32 kHz input rate.
/// A trailing window that would run past the end of the buffer is dropped; the caller pads or waits.
public struct WindowPlanner: Sendable, Equatable {
    public let sampleRate: Int
    public let windowDuration: Double
    public let hopDuration: Double

    public init(sampleRate: Int = 32_000, windowDuration: Double = 3, hopDuration: Double = 1.5) {
        precondition(sampleRate > 0, "sampleRate must be positive")
        precondition(windowDuration > 0, "windowDuration must be positive")
        precondition(hopDuration > 0 && hopDuration <= windowDuration, "hop must be in (0, window]")
        self.sampleRate = sampleRate
        self.windowDuration = windowDuration
        self.hopDuration = hopDuration
    }

    /// Number of samples in one window.
    public var windowLength: Int { Int((windowDuration * Double(sampleRate)).rounded()) }

    /// Number of samples between consecutive window starts.
    public var hopLength: Int { Int((hopDuration * Double(sampleRate)).rounded()) }

    /// Sample ranges of every complete window that fits in `count` samples, in order.
    public func windows(forSampleCount count: Int) -> [Range<Int>] {
        guard count >= windowLength else { return [] }
        return stride(from: 0, through: count - windowLength, by: hopLength).map { $0..<($0 + windowLength) }
    }
}
