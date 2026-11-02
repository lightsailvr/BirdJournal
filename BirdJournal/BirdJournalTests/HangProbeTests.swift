import Foundation
import Testing

// Deliberately hung tests that prove the timeouts in `scripts/build-and-test.sh` (issue #82): skipped unless the
// test process gets `BIRDJOURNAL_HANG_PROBE` (xcodebuild passes `TEST_RUNNER_BIRDJOURNAL_HANG_PROBE=…` through). Run
// them with `scripts/build-and-test.sh --hang-probe <kind>`. `await` waits on a continuation nobody resumes (a hang
// cancellation cannot end) and `spin` busy-loops a thread like the toolkit's spin in #82, each under a one-minute time
// limit. `silent` blocks without a word and has no time limit: xcodebuild's execution time allowance ends it, and with
// the allowance raised past the watchdog (`BIRDJOURNAL_TEST_ALLOWANCE=3000 BIRDJOURNAL_QUIET_MINUTES=2`) the watchdog.
@Suite("Hang probe", .serialized)
struct HangProbeTests {
    nonisolated private static let kind = ProcessInfo.processInfo.environment["BIRDJOURNAL_HANG_PROBE"]

    @Test("awaits forever", .enabled(if: kind == "await"), .timeLimit(.minutes(1)))
    func awaitsForever() async {
        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
    }

    @Test("spins a thread forever", .enabled(if: kind == "spin"), .timeLimit(.minutes(1)))
    func spinsForever() async {
        let spinning = Thread {
            var counter: UInt64 = 0
            while true { counter &+= 1 }
        }
        spinning.start()
        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
    }

    @Test("blocks silently past every limit", .enabled(if: kind == "silent"))
    func blocksSilently() {
        Thread.sleep(forTimeInterval: 60 * 60)
    }
}
