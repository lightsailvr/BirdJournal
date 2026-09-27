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
    /// Pairs a mock Display (registered, permissions granted, powered on, unfolded, worn) and always disables
    /// Mock Device Kit afterwards, so a failing test does not leave the next one with a stale device.
    static func withMockDisplay(_ body: (any MockGlasses) async throws -> Void) async throws {
        MockDeviceKit.shared.enable()
        do {
            let glasses = try MockDeviceKit.shared.pairGlasses(model: .metaRayBanDisplay)
            glasses.powerOn()
            glasses.unfold()
            glasses.don()
            try await body(glasses)
        } catch {
            await MockDeviceKit.shared.disable()
            throw error
        }
        await MockDeviceKit.shared.disable()
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
