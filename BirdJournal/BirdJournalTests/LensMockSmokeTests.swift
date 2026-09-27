import Identification
import LensSession
import MWDATCore
import MWDATDisplay
import MWDATInputs
import MWDATMockDevice
import Testing
@testable import BirdJournal

// Lens pages on Mock Device Kit (issue #7): session started, Display and Inputs attached, the fake stack fed in,
// every page reached with injected nav, select and back, and a clean stop.
extension MockDeviceKitTests {
    @Suite("Lens session")
    struct Lens {
        @Test("injected nav, select and back walk every page, and a new species never moves the page")
        func navigatesAllPages() async throws {
            try await withRunningLens { lens, glasses in
                lens.savedDismissDelay = .seconds(30) // The test, not the timer, leaves the Saved page.
                #expect(lens.page == .listening)
                #expect(lens.card.elements[1] == .body("No species yet"))

                lens.update(with: FakeLensStack.stack(count: 2))
                #expect(lens.page == .listening)
                #expect(lens.card.elements[1] == .body("2 species heard"))

                let input = glasses.services.input
                let steps: [(inject: () -> Void, page: LensPage)] = [
                    (input.navLeft, .photo(index: 0)),
                    (input.navDown, .description(index: 0)),
                    (input.navUp, .photo(index: 0)),
                    (input.select, .confirm(index: 0)),
                    (input.select, .saved(index: 0)),
                    (input.navUp, .photo(index: 0)),
                    (input.navLeft, .photo(index: 1)),
                ]
                for step in steps {
                    step.inject()
                    try await waitUntil(timeout: .seconds(1)) { lens.page == step.page }
                }
                #expect(lens.savedSightings.map(\.species) == [FakeLensStack.species[0]])
                #expect(lens.card.elements.contains(.heading("House Finch")))

                // A species arriving while on a photo page appends and leaves the page alone.
                lens.update(with: FakeLensStack.stack(count: 3))
                #expect(lens.page == .photo(index: 1))
                #expect(lens.stack.count == 3)
                #expect(lens.card.elements.contains(.meta("2 of 3")))

                input.navRight()
                try await waitUntil(timeout: .seconds(1)) { lens.page == .photo(index: 0) }
                input.navUp()
                try await waitUntil(timeout: .seconds(1)) { lens.page == .listening }
                #expect(lens.card.elements[1] == .body("3 species heard"))

                // Back on the root ends the session.
                input.back()
                try await waitUntil(timeout: .seconds(2)) { lens.phase == .stopped(.back) }
                #expect(lens.inputsState == .inactive)
                #expect(lens.inputRecords.first?.gesture == .back)
                #expect(lens.errorMessage == nil)
            }
        }

        @Test("the Saved page returns to the photo on its own")
        func savedPageDismisses() async throws {
            try await withRunningLens { lens, glasses in
                lens.savedDismissDelay = .milliseconds(200)
                lens.update(with: FakeLensStack.stack(count: 1))
                let input = glasses.services.input
                input.navLeft()
                try await waitUntil(timeout: .seconds(1)) { lens.page == .photo(index: 0) }
                input.select()
                try await waitUntil(timeout: .seconds(1)) { lens.page == .confirm(index: 0) }
                input.select()
                try await waitUntil(timeout: .seconds(1)) { lens.page == .saved(index: 0) }
                try await waitUntil(timeout: .seconds(2)) { lens.page == .photo(index: 0) }
                #expect(lens.savedSightings.count == 1)
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

        /// Starts a lens session with the fake stack's profiles on a connected mock Display, waits for Inputs to be
        /// active, and always stops it.
        private func withRunningLens(_ body: (GlassesLensSession, any MockGlasses) async throws -> Void) async throws {
            try await withMockDisplay { glasses in
                let connection = GlassesConnection()
                try await waitUntil { connection.connectedDevice != nil }
                let lens = GlassesLensSession(profile: FakeLensStack.profile(for:), image: FakeLensStack.image(for:))
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
