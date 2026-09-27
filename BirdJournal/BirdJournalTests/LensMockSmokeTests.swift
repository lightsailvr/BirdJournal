import LensSession
import MWDATCore
import MWDATDisplay
import MWDATInputs
import MWDATMockDevice
import Testing
@testable import BirdJournal

// Lens round trip on Mock Device Kit (issue #4): session started, Display and Inputs attached, one card sent,
// every injected Nav and Select echoed on the phone and onto the card, and a clean stop.
extension MockDeviceKitTests {
    @Suite("Lens session")
    struct Lens {
        @Test("the card reaches the mock lens and every nav and select is echoed within a second")
        func gestureRoundTrip() async throws {
            try await withRunningLens { lens, glasses in
                #expect(lens.card.body == "Swipe or tap to test the Neural Band.")

                let input = glasses.services.input
                let expected: [(inject: () -> Void, gesture: LensGesture)] = [
                    (input.navLeft, .swipeLeft),
                    (input.navRight, .swipeRight),
                    (input.navUp, .swipeUp),
                    (input.navDown, .swipeDown),
                    (input.select, .tap),
                ]
                for (index, step) in expected.enumerated() {
                    step.inject()
                    try await waitUntil(timeout: .seconds(1)) { lens.echo.count == index + 1 }
                    #expect(lens.echo.lastGesture == step.gesture)
                    #expect(lens.inputRecords.first?.gesture == step.gesture)
                }
                #expect(lens.card.body == "Tap · 5 gestures")
                #expect(lens.inputRecords.map(\.gesture) == [.tap, .swipeDown, .swipeUp, .swipeRight, .swipeLeft])
            }
        }

        @Test("back is recorded on the phone but is not a gesture")
        func backIsIgnored() async throws {
            try await withRunningLens { lens, glasses in
                glasses.services.input.back()
                try await waitUntil(timeout: .seconds(1)) { !lens.inputRecords.isEmpty }
                #expect(lens.inputRecords.first?.gesture == nil)
                #expect(lens.echo.count == 0)
            }
        }

        @Test("inputs is attached only once the session is started, and stop releases everything")
        func lifecycle() async throws {
            try await withMockDisplay { _ in
                let connection = GlassesConnection()
                try await waitUntil { connection.connectedDevice != nil }
                let lens = GlassesLensSession()
                #expect(lens.inputsState == .inactive)

                await lens.start()
                #expect(lens.phase == .running)
                // The mirrored states arrive through their own listener hops, a beat after `start()` returns.
                try await waitUntil { lens.sessionState == .started }
                try await waitUntil { lens.displayState == .started }
                try await waitUntil { lens.inputsState == .active }

                await lens.stop()
                #expect(lens.phase == .stopped(.phone))
                #expect(lens.inputsState == .inactive)
                #expect(lens.displayState == .stopped)
                #expect(lens.sessionState == .stopped)
                #expect(lens.errorMessage == nil)
            }
        }

        @Test("a session the glasses end is reported as ended by the glasses")
        func endedByGlasses() async throws {
            try await withMockDisplay { glasses in
                let connection = GlassesConnection()
                try await waitUntil { connection.connectedDevice != nil }
                let lens = GlassesLensSession()
                await lens.start()
                try #require(lens.phase == .running, "\(lens.errorMessage ?? "no error")")

                glasses.powerOff()
                try await waitUntil { lens.phase == .stopped(.glasses) }
                #expect(lens.inputsState == .inactive)
                #expect(lens.sessionState == .stopped)
                await lens.stop() // No-op once ended; must not change the reason.
                #expect(lens.phase == .stopped(.glasses))
            }
        }

        /// Starts a lens session on a connected mock Display, waits for Inputs to be active, and always stops it.
        private func withRunningLens(_ body: (GlassesLensSession, any MockGlasses) async throws -> Void) async throws {
            try await withMockDisplay { glasses in
                let connection = GlassesConnection()
                try await waitUntil { connection.connectedDevice != nil }
                let lens = GlassesLensSession()
                await lens.start()
                do {
                    try #require(lens.phase == .running, "\(lens.errorMessage ?? "no error")")
                    try await waitUntil { lens.inputsState == .active }
                    try await body(lens, glasses)
                } catch {
                    await lens.stop()
                    throw error
                }
                await lens.stop()
            }
        }
    }
}
