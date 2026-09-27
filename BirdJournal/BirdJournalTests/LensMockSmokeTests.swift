import Identification
import LensSession
import MWDATCore
import MWDATDisplay
import MWDATInputs
import MWDATMockDevice
import Testing
@testable import BirdJournal

// Lens pages on Mock Device Kit (issues #7 and #24): session started, Display and Inputs attached, the fake stack
// fed in, the list and every species card reached with injected nav, select and back, and a clean stop.
extension MockDeviceKitTests {
    @Suite("Lens session")
    struct Lens {
        @Test("injected nav, select and back walk the list and the cards, and a new species never moves the page")
        func navigatesAllPages() async throws {
            try await withRunningLens { lens, glasses in
                #expect(lens.page == .list(screenful: 0))
                #expect(lens.card.elements[0] == .heading("No species yet"))

                lens.update(with: FakeLensStack.stack(count: 2))
                #expect(lens.page == .list(screenful: 0))
                #expect(lens.card.elements[0] == .heading("2 species heard"))

                let input = glasses.services.input
                input.navLeft()
                try await waitUntil(timeout: .seconds(1)) { lens.page == .species(index: 0, screenful: 0) }
                #expect(lens.card.photo == LensImage(id: "sayornis-nigricans"))
                #expect(lens.card.screenfuls[0].contains(.title("Black Phoebe", detail: "82% match")))

                // Down pages to the text screenful and stops at the card's end; up comes back.
                input.navDown()
                try await waitUntil(timeout: .seconds(1)) { lens.page == .species(index: 0, screenful: 1) }
                input.navDown()
                try await waitUntil(timeout: .seconds(1)) { lens.inputRecords.count == 3 }
                #expect(lens.page == .species(index: 0, screenful: 1))
                input.navUp()
                try await waitUntil(timeout: .seconds(1)) { lens.page == .species(index: 0, screenful: 0) }

                // "This is my bird": one Select saves, the card shows it, and a second Select saves nothing more.
                input.select()
                try await waitUntil(timeout: .seconds(1)) { lens.savedSightings.count == 1 }
                #expect(lens.savedSightings.map(\.species) == [FakeLensStack.species[0]])
                #expect(lens.page == .species(index: 0, screenful: 0))
                #expect(lens.card.elements.last == .saved("Saved ✓"))
                #expect(lens.card.elements.first == .status("2 species · 1 of 2 · Saved"))
                input.select()
                try await waitUntil(timeout: .seconds(1)) { lens.inputRecords.count == 6 }
                #expect(lens.savedSightings.count == 1)

                input.navLeft()
                try await waitUntil(timeout: .seconds(1)) { lens.page == .species(index: 1, screenful: 0) }
                #expect(lens.card.screenfuls[0].contains(.title("House Finch", detail: "61% match")))

                // A species arriving while on a card appends, updates the strip and leaves the page alone.
                lens.update(with: FakeLensStack.stack(count: 3))
                #expect(lens.page == .species(index: 1, screenful: 0))
                #expect(lens.stack.count == 3)
                #expect(lens.card.elements.first == .status("3 species · 2 of 3"))
                #expect(lens.card.photo == LensImage(id: "haemorhous-mexicanus"))

                input.navRight()
                try await waitUntil(timeout: .seconds(1)) { lens.page == .species(index: 0, screenful: 0) }
                input.navRight()
                try await waitUntil(timeout: .seconds(1)) { lens.page == .list(screenful: 0) }
                #expect(lens.card.elements[0] == .heading("3 species heard"))
                guard case .list(let rows) = lens.card.elements[2] else { Issue.record("no rows on the list"); return }
                #expect(rows.map(\.isSaved) == [true, false, false])
                #expect(rows.map(\.hasPhoto) == [true, true, true])

                // Back on the root ends the session.
                input.back()
                try await waitUntil(timeout: .seconds(2)) { lens.phase == .stopped(.back) }
                #expect(lens.inputsState == .inactive)
                #expect(lens.inputRecords.first?.gesture == .back)
                #expect(lens.errorMessage == nil)
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
