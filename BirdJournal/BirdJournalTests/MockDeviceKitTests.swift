import Identification
import LensSession
import MWDATCore
import MWDATMockDevice
import Testing
import UIKit
@testable import BirdJournal

// Root of every Mock Device Kit suite (spec "Testing"). They run app-hosted because `Wearables.configure()`
// needs the host app's bundle; the app calls it at launch. `.serialized` is recursive, so the nested suites
// never share `MockDeviceKit.shared` at the same time.
@Suite("Mock Device Kit", .serialized)
enum MockDeviceKitTests {
    /// Pairs a mock Display (registered, permissions granted, powered on, unfolded, worn), waits until that device
    /// (not any device) is connected, and always tears it down afterwards, so a failing test does not leave the next
    /// one with a stale device.
    static func withMockDisplay(_ body: (any MockGlasses) async throws -> Void) async throws {
        MockDeviceKit.shared.enable()
        var paired: (any MockGlasses)?
        do {
            let glasses = try MockDeviceKit.shared.pairGlasses(model: .metaRayBanDisplay)
            paired = glasses
            glasses.powerOn()
            glasses.unfold()
            glasses.don()
            try await waitUntil {
                Wearables.shared.deviceForIdentifier(glasses.deviceIdentifier)?.linkState == .connected
            }
            try await body(glasses)
        } catch {
            await tearDown(paired)
            throw error
        }
        await tearDown(paired)
    }

    /// Unpairs, then disables, each awaited (the DAT docs' deterministic teardown, issue #82), then waits for the
    /// device to leave `Wearables.shared.devices` and gives the toolkit's link a beat to close: `disable()` returns
    /// while the link's stream I/O may still be closing on the toolkit's thread.
    private static func tearDown(_ glasses: (any MockGlasses)?) async {
        if let glasses { await MockDeviceKit.shared.unpairDevice(glasses) }
        await MockDeviceKit.shared.disable()
        let deadline = ContinuousClock.now + .seconds(5)
        while !Wearables.shared.devices.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        try? await Task.sleep(for: .milliseconds(300))
    }

    /// The mock camera needs a feed or the stream fails with `videoStreamingError`.
    static func makeFeedImage() throws -> URL {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 360, height: 640)).image { context in
            UIColor.darkGray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 360, height: 640))
        }
        let url = URL.temporaryDirectory.appending(path: "mock-feed.png")
        try #require(image.pngData()).write(to: url)
        return url
    }

    /// Moves the list highlight to the species at stack `index`, whatever the list order (issue #42: the calling
    /// bird heads the list and two birds admitted in one window tie on recency), and opens its photo page. Returns
    /// how many gestures it sent.
    @discardableResult
    static func openSpecies(_ index: Int, on lens: GlassesLensSession, glasses: any MockGlasses) async throws -> Int {
        let input = glasses.services.input
        var sent = 0
        for _ in 0..<lens.stack.count where lens.machine.selection != index {
            let position = lens.machine.order.position(of: lens.machine.selection) ?? 0
            let target = lens.machine.order.position(of: index) ?? 0
            let before = lens.inputRecords.count
            if target > position { input.navDown() } else { input.navUp() }
            sent += 1
            try await waitUntil(timeout: .seconds(1)) { lens.inputRecords.count == before + 1 }
        }
        input.navLeft()
        sent += 1
        try await waitUntil(timeout: .seconds(1)) { lens.page == .species(index: index) }
        return sent
    }

    static func waitUntil(
        timeout: Duration = .seconds(15),
        _ condition: () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Condition not met within \(timeout)", sourceLocation: sourceLocation)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
