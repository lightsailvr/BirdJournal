import Foundation
import Testing

// Deliberately hung tests that prove the timeouts in `scripts/build-and-test.sh` (issue #82): skipped unless the
// test process gets `BIRDJOURNAL_HANG_PROBE` (xcodebuild passes `TEST_RUNNER_BIRDJOURNAL_HANG_PROBE=…` through). Run
// them with `scripts/build-and-test.sh --hang-probe <kind>`. `await` waits on a continuation nobody resumes (a hang
// cancellation cannot end), `spin` busy-loops a thread like the toolkit's spin in #82, and `silent` sleeps past the
// watchdog without a word, on its own suite with no time limit, so only the watchdog can end it.
@Suite("Hang probe", .serialized)
struct HangProbeTests {
    private static let kind = ProcessInfo.processInfo.environment["BIRDJOURNAL_HANG_PROBE"]

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

    @Test("sleeps silently past the watchdog", .enabled(if: kind == "silent"))
    func sleepsSilently() {
        Thread.sleep(forTimeInterval: 60 * 60)
    }
}
