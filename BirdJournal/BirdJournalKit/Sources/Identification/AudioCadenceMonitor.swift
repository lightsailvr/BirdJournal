/// A stretch with no audio: from the last chunk's arrival (or the start) to the next arrival (or now).
public struct AudioGap: Sendable, Equatable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    public var duration: Double { end - start }
}

/// Cadence and latency for one reporting interval, plus running totals.
public struct CadenceSummary: Sendable, Equatable {
    /// Chunks received in the interval.
    public var chunks: Int
    /// Seconds of audio received in the interval.
    public var audioSeconds: Double
    /// Seconds of wall time the interval covered.
    public var wallSeconds: Double
    /// Mean and longest time between consecutive arrivals ending in the interval; nil without any.
    public var meanInterval: Double?
    public var maxInterval: Double?
    /// Gaps that ended in the interval.
    public var gaps: Int
    /// Mean and largest latency above the baseline over the interval's chunks; nil without any.
    public var latencyMean: Double?
    public var latencyMax: Double?
    /// Arrival minus presentation time of the very first chunk. Absolute latency when the source stamps
    /// presentation times on the same clock as arrivals; otherwise only a clock offset.
    public var firstOffset: Double?
    /// Time since the most recent chunk arrived; nil if none has.
    public var secondsSinceLastChunk: Double?
    public var totalChunks: Int
    public var totalGaps: Int
}

/// Watches chunk arrivals for the phase A audio spike: detects gaps longer than a threshold and summarizes
/// cadence and latency per reporting interval.
///
/// Latency is measured without a clock shared with the glasses: each chunk's offset is its arrival time minus
/// its presentation time, and latency is how far that offset sits above the lowest offset seen since the last
/// gap. That is the extra delay over the best case, which is what grows when the link backs up. A gap restarts
/// the baseline because a paused stream may restart its presentation clock.
public struct AudioCadenceMonitor: Sendable {
    public let gapThreshold: Double
    public let startedAt: Double

    private var intervalStart: Double
    private var lastArrival: Double?
    private var baselineOffset: Double?
    private var firstOffset: Double?
    private var totalChunks = 0
    private var totalGaps = 0

    private var chunks = 0
    private var audioSeconds = 0.0
    private var intervalSum = 0.0
    private var intervalCount = 0
    private var maxInterval: Double?
    private var gaps = 0
    private var latencySum = 0.0
    private var latencyMax: Double?

    public init(startedAt: Double, gapThreshold: Double = 2) {
        precondition(gapThreshold > 0, "gapThreshold must be positive")
        self.startedAt = startedAt
        self.intervalStart = startedAt
        self.gapThreshold = gapThreshold
    }

    /// Records a chunk that arrived at `arrivedAt` and returns the gap it closed, if the time since the previous
    /// arrival exceeds the threshold. The first chunk never closes a gap; startup time is the caller's to log.
    public mutating func record(_ chunk: AudioChunk, arrivedAt: Double) -> AudioGap? {
        var closedGap: AudioGap?
        if let lastArrival {
            let interval = arrivedAt - lastArrival
            intervalSum += interval
            intervalCount += 1
            maxInterval = max(maxInterval ?? interval, interval)
            if interval > gapThreshold {
                closedGap = AudioGap(start: lastArrival, end: arrivedAt)
                gaps += 1
                totalGaps += 1
                baselineOffset = nil
            }
        }

        let offset = arrivedAt - chunk.presentationTime
        firstOffset = firstOffset ?? offset
        let baseline = min(baselineOffset ?? offset, offset)
        baselineOffset = baseline
        let latency = offset - baseline
        latencySum += latency
        latencyMax = max(latencyMax ?? latency, latency)

        chunks += 1
        totalChunks += 1
        audioSeconds += chunk.duration
        lastArrival = arrivedAt
        return closedGap
    }

    /// Summarizes the interval since the previous summary (or the start) and begins a new one at `now`.
    public mutating func summarize(at now: Double) -> CadenceSummary {
        let summary = CadenceSummary(
            chunks: chunks,
            audioSeconds: audioSeconds,
            wallSeconds: now - intervalStart,
            meanInterval: intervalCount > 0 ? intervalSum / Double(intervalCount) : nil,
            maxInterval: maxInterval,
            gaps: gaps,
            latencyMean: chunks > 0 ? latencySum / Double(chunks) : nil,
            latencyMax: latencyMax,
            firstOffset: firstOffset,
            secondsSinceLastChunk: lastArrival.map { now - $0 },
            totalChunks: totalChunks,
            totalGaps: totalGaps
        )
        intervalStart = now
        chunks = 0
        audioSeconds = 0
        intervalSum = 0
        intervalCount = 0
        maxInterval = nil
        gaps = 0
        latencySum = 0
        latencyMax = nil
        return summary
    }

    /// The silence still in progress at `now`, if it already exceeds the threshold. Used when the spike stops.
    public func openGap(at now: Double) -> AudioGap? {
        let start = lastArrival ?? startedAt
        return now - start > gapThreshold ? AudioGap(start: start, end: now) : nil
    }
}
