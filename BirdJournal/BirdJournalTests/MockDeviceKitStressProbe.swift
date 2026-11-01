import Foundation
import MWDATCore
import MWDATMockDevice
import Testing
import UIKit
@testable import BirdJournal

// Issue #82's repro: cycles a mock Display through pair, a started session with a camera stream, and teardown, over
// and over in one test host, until the toolkit's mock link stops answering. Skipped unless the test process gets
// `BIRDJOURNAL_MDK_STRESS=<cycles>` (pass `TEST_RUNNER_BIRDJOURNAL_MDK_STRESS=40` to xcodebuild).
// `BIRDJOURNAL_MDK_TEARDOWN` picks the teardown: `bare` (enable … disable, as the suites did before #82) or `settled`
// (`MockDeviceKitTests.withMockDisplay` as it is now).
@Suite("Mock Device Kit stress probe", .serialized)
struct MockDeviceKitStressProbe {
    private static let cycles = ProcessInfo.processInfo.environment["BIRDJOURNAL_MDK_STRESS"].flatMap(Int.init)
    private static let teardown = ProcessInfo.processInfo.environment["BIRDJOURNAL_MDK_TEARDOWN"] ?? "settled"

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
            if Self.teardown == "bare" {
                MockDeviceKit.shared.enable()
                let glasses = try MockDeviceKit.shared.pairGlasses(model: .metaRayBanDisplay)
                glasses.powerOn()
                glasses.unfold()
                glasses.don()
                let connection = GlassesConnection()
                try await MockDeviceKitTests.waitUntil { connection.connectedDevice != nil }
                do { try await body(glasses) } catch { await MockDeviceKit.shared.disable(); throw error }
                await MockDeviceKit.shared.disable()
            } else {
                try await MockDeviceKitTests.withMockDisplay(body)
            }
            print("stress cycle \(cycle) (\(Self.teardown)) passed in \(ContinuousClock.now - started)")
        }
    }
}

private final class Flag: @unchecked Sendable {
    var value = false
}
