import Foundation
import MWDATCamera
import MWDATCore
import MWDATMockDevice
import Testing
import UIKit
@testable import BirdJournal

// Issue #82's repro: cycles a mock Display through pair, a started session with a camera stream, and teardown, over
// and over in one test host, until the toolkit's mock link stops answering. Skipped unless the test process gets
// `BIRDJOURNAL_MDK_STRESS=<cycles>`. 40 cycles take about 5 minutes, past the script's default allowance:
//   TEST_RUNNER_BIRDJOURNAL_MDK_STRESS=40 BIRDJOURNAL_TEST_ALLOWANCE=1800 BIRDJOURNAL_TEST_MAX_ALLOWANCE=1800 \
//   BIRDJOURNAL_SIMULATOR=BJ-<n> scripts/build-and-test.sh -only-testing:BirdJournalTests/MockDeviceKitStressProbe
// `BIRDJOURNAL_MDK_TEARDOWN` picks the teardown: `bare` (enable … disable, as the suites did before #82), `unpair`
// (bare plus an awaited `unpairDevice` before `disable`), `settle` (bare plus a wait for the device list to empty and
// a 300 ms beat after `disable`), or `settled` (`MockDeviceKitTests.withMockDisplay` as it is now: all of it).
@Suite("Mock Device Kit stress probe", .serialized)
struct MockDeviceKitStressProbe {
    nonisolated private static let cycles = ProcessInfo.processInfo.environment["BIRDJOURNAL_MDK_STRESS"].flatMap(Int.init)
    nonisolated private static let teardown = ProcessInfo.processInfo.environment["BIRDJOURNAL_MDK_TEARDOWN"] ?? "settled"

    @Test("the mock link keeps answering through repeated pair, stream and teardown cycles", .enabled(if: cycles != nil), .timeLimit(.minutes(30)))
    func cyclesUntilWedged() async throws {
        let feed = try MockDeviceKitTests.makeFeedImage()
        for cycle in 1...(Self.cycles ?? 0) {
            let started = ContinuousClock.now
            let body: (any MockGlasses) async throws -> Void = { glasses in
                glasses.services.camera.setCameraFeed(fileURL: feed)
                // Every request below goes over the mock link; a wedged link never answers, so each is bounded.
                let answered = await completes(within: .seconds(20)) {
                    (try? await Wearables.shared.checkPermissionStatus(.camera)) != nil
                }
                try #require(answered, "cycle \(cycle): the mock link stopped answering a permission check")
                let source = GlassesAudioSource()
                let streaming = Flag()
                let watcher = Task { for await event in source.events { if case .streamState(.streaming) = event { streaming.value = true } } }
                defer { watcher.cancel() }
                let didStart = await completes(within: .seconds(30)) { (try? await source.start()) != nil }
                try #require(didStart, "cycle \(cycle): the audio source did not start")
                try await MockDeviceKitTests.waitUntil(timeout: .seconds(20)) { streaming.value }
                await source.stop()
            }
            if Self.teardown != "settled" {
                MockDeviceKit.shared.enable()
                let glasses = try MockDeviceKit.shared.pairGlasses(model: .metaRayBanDisplay)
                glasses.powerOn()
                glasses.unfold()
                glasses.don()
                let connection = GlassesConnection()
                try await MockDeviceKitTests.waitUntil { connection.connectedDevice != nil }
                let tearDown = {
                    if Self.teardown == "unpair" { await MockDeviceKit.shared.unpairDevice(glasses) }
                    if Self.teardown == "settle" {
                        await GlassesConnection.settleMockDeviceKit()
                    } else {
                        await MockDeviceKit.shared.disable()
                    }
                }
                do { try await body(glasses) } catch { await tearDown(); throw error }
                await tearDown()
            } else {
                try await MockDeviceKitTests.withMockDisplay(body)
            }
            print("stress cycle \(cycle) (\(Self.teardown)) passed in \(ContinuousClock.now - started)")
        }
    }
}

private final class Flag {
    var value = false
}
