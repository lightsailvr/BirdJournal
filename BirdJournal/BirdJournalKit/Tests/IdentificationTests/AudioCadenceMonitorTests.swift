import Testing
@testable import Identification

// Phase A spike (issue #3): chunks must arrive continuously; gaps longer than 2 s are logged, and every 30 s the
// log records cadence and latency. Times are seconds; quarter-second steps keep the arithmetic exact.
@Suite("AudioCadenceMonitor")
struct AudioCadenceMonitorTests {
    @Test("steady chunks produce no gaps and a full summary")
    func steady() {
        var monitor = AudioCadenceMonitor(startedAt: 0)
        for i in 1...4 {
            let gap = monitor.record(chunk(pts: Double(i) * 0.25), arrivedAt: Double(i) * 0.25)
            #expect(gap == nil)
        }

        let summary = monitor.summarize(at: 1)

        #expect(summary.chunks == 4)
        #expect(summary.audioSeconds == 1)
        #expect(summary.wallSeconds == 1)
        #expect(summary.meanInterval == 0.25)
        #expect(summary.maxInterval == 0.25)
        #expect(summary.gaps == 0)
        #expect(summary.secondsSinceLastChunk == 0)
    }

    @Test("an arrival more than 2 s after the previous one is a gap")
    func gapDetected() {
        var monitor = AudioCadenceMonitor(startedAt: 0)
        _ = monitor.record(chunk(pts: 0), arrivedAt: 1)

        let gap = monitor.record(chunk(pts: 2.5), arrivedAt: 3.5)

        #expect(gap == AudioGap(start: 1, end: 3.5))
        #expect(gap?.duration == 2.5)
        #expect(monitor.summarize(at: 4).gaps == 1)
    }

    @Test("exactly 2 s between arrivals is not a gap")
    func thresholdIsExclusive() {
        var monitor = AudioCadenceMonitor(startedAt: 0)
        _ = monitor.record(chunk(pts: 0), arrivedAt: 1)
        #expect(monitor.record(chunk(pts: 2), arrivedAt: 3) == nil)
    }

    @Test("summaries reset per interval while totals keep counting")
    func intervalReset() {
        var monitor = AudioCadenceMonitor(startedAt: 0)
        _ = monitor.record(chunk(pts: 0), arrivedAt: 1)
        _ = monitor.record(chunk(pts: 5), arrivedAt: 6)
        _ = monitor.summarize(at: 30)

        _ = monitor.record(chunk(pts: 30), arrivedAt: 31)
        let second = monitor.summarize(at: 60)

        #expect(second.chunks == 1)
        #expect(second.gaps == 1)
        #expect(second.wallSeconds == 30)
        #expect(second.maxInterval == 25)
        #expect(second.totalChunks == 3)
        #expect(second.totalGaps == 2)
    }

    @Test("an interval with no chunks reports how long the source has been silent")
    func silentInterval() {
        var monitor = AudioCadenceMonitor(startedAt: 0)
        _ = monitor.record(chunk(pts: 0), arrivedAt: 5)

        _ = monitor.summarize(at: 30)
        let silent = monitor.summarize(at: 60)

        #expect(silent.chunks == 0)
        #expect(silent.meanInterval == nil)
        #expect(silent.latencyMean == nil)
        #expect(silent.secondsSinceLastChunk == 55)
    }

    @Test("no chunks at all leaves time since last chunk unknown")
    func neverReceived() {
        var monitor = AudioCadenceMonitor(startedAt: 0)
        #expect(monitor.summarize(at: 30).secondsSinceLastChunk == nil)
    }

    @Test("latency is measured above the lowest arrival-minus-presentation offset seen so far")
    func latencyAboveBaseline() {
        var monitor = AudioCadenceMonitor(startedAt: 0)
        _ = monitor.record(chunk(pts: 0), arrivedAt: 10)        // offset 10, baseline 10
        _ = monitor.record(chunk(pts: 0.25), arrivedAt: 10.75)  // offset 10.5 → 0.5 above
        _ = monitor.record(chunk(pts: 0.5), arrivedAt: 10.5)    // offset 10 → 0 above

        let summary = monitor.summarize(at: 11)

        #expect(summary.latencyMax == 0.5)
        #expect(summary.latencyMean == 0.5 / 3)
        #expect(summary.firstOffset == 10)
    }

    @Test("a gap restarts the latency baseline, since a paused stream may restart its clock")
    func gapResetsBaseline() {
        var monitor = AudioCadenceMonitor(startedAt: 0)
        _ = monitor.record(chunk(pts: 0), arrivedAt: 1)         // offset 1
        _ = monitor.summarize(at: 2)

        _ = monitor.record(chunk(pts: 0), arrivedAt: 10)        // gap; clock restarted, offset 10, new baseline
        _ = monitor.record(chunk(pts: 0.25), arrivedAt: 10.25)  // offset 10 → 0 above

        #expect(monitor.summarize(at: 11).latencyMax == 0)
    }

    @Test("stopping during a silence reports the open gap")
    func openGapOnStop() {
        var monitor = AudioCadenceMonitor(startedAt: 0)
        _ = monitor.record(chunk(pts: 0), arrivedAt: 1)

        #expect(monitor.openGap(at: 2) == nil)
        #expect(monitor.openGap(at: 4) == AudioGap(start: 1, end: 4))
    }

    @Test("a source that never delivers is an open gap from the start")
    func openGapWithoutChunks() {
        let monitor = AudioCadenceMonitor(startedAt: 0)
        #expect(monitor.openGap(at: 3) == AudioGap(start: 0, end: 3))
    }

    private func chunk(pts: Double) -> AudioChunk {
        // A quarter second at 16 kHz.
        AudioChunk(samples: [Float](repeating: 0, count: 4_000), sampleRate: 16_000, presentationTime: pts)
    }
}
