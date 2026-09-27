import Foundation
import Identification
import LensSession
import MWDATCore
import MWDATDisplay
import MWDATInputs
import Observation
import Synchronization
import UIKit

/// The glasses adapter for the lens (spec "Glasses adapter"): one device session with Display and Inputs attached,
/// the `LensStateMachine` fed with stack updates and every Nav, Select and Back the glasses deliver, and the page it
/// lands on rendered onto the lens after each change.
///
/// Order (DAT-SETUP-CHECKLIST.md): Display attaches once the session is `.started`, the first card is sent once
/// Display is `.started`, and Inputs attaches last, with `consumeBack` so a Back event reaches the app when
/// hardware delivers one. Real Display glasses end the session themselves on the two-finger tap, which arrives
/// as `.stopped` and is reported as `StopReason.glasses`. Each `start` begins a fresh page state.
@Observable
final class GlassesLensSession {
    enum Phase: Equatable {
        case idle
        case starting
        case running
        case stopping
        case stopped(StopReason)
    }

    enum StopReason: Equatable {
        /// Stop was tapped on the phone.
        case phone
        /// Back on the listening page (the root) ended the session.
        case back
        /// The session ended on the device side (two-finger tap, doff, link loss).
        case glasses
        case failed(String)
    }

    enum StartError: LocalizedError {
        case noDisplayGlasses
        /// Carries the session error reported before the session stopped, if any.
        case sessionDidNotStart(DeviceSessionError?)
        case displayDidNotStart
        case inputsUnavailable

        var errorDescription: String? {
            switch self {
            case .noDisplayGlasses: "No connected display glasses."
            case .sessionDidNotStart(let error?): "The glasses session did not start: \(error.description)"
            case .sessionDidNotStart(nil): "The glasses session did not start."
            case .displayDidNotStart: "The lens display did not start."
            case .inputsUnavailable: "Inputs could not be attached: the session is not started."
            }
        }
    }

    /// One input event as the glasses delivered it.
    struct InputRecord: Identifiable, Equatable {
        let id = UUID()
        let receivedAt: Date
        let description: String
        /// The gesture it maps to, or nil for events the lens ignores (buttons, capture, drag).
        let gesture: LensGesture?
    }

    static let maxRecords = 100

    private(set) var phase: Phase = .idle
    private(set) var sessionState: DeviceSessionState = .idle
    private(set) var displayState: DisplayState = .stopped
    private(set) var inputsState: InputsState = .inactive
    private(set) var machine = LensStateMachine()
    /// What the lens shows, kept in step with `machine`.
    private(set) var card: LensCard
    /// Candidates confirmed this run, newest last. Writing them to the album is issue #9.
    private(set) var savedSightings: [Candidate] = []
    /// Newest first, capped at `maxRecords`.
    private(set) var inputRecords: [InputRecord] = []
    /// How long the Saved page stays before the photo returns on its own.
    var savedDismissDelay: Duration = .seconds(2)
    var errorMessage: String?

    @ObservationIgnored private let wearables: any WearablesInterface
    @ObservationIgnored private let connection: GlassesConnection?
    /// Pack lookup for the photo and description pages.
    @ObservationIgnored private let profile: (Species) -> SpeciesProfile?
    /// Pixels for the images the pack names.
    @ObservationIgnored private let image: (LensImage) -> UIImage?
    @ObservationIgnored private var session: DeviceSession?
    @ObservationIgnored private var display: Display?
    @ObservationIgnored private var inputsCapability: Inputs?
    @ObservationIgnored private var inputTask: Task<Void, Never>?
    @ObservationIgnored private var savedTask: Task<Void, Never>?
    /// Sends run one after another so a burst of gestures leaves the latest card on the lens.
    @ObservationIgnored private var sendTask: Task<Void, Never>?
    @ObservationIgnored private let tokens = ListenerTokenBag()
    /// Written straight from the toolkit callback, so a failed start can report it without waiting for a hop.
    @ObservationIgnored private nonisolated let lastSessionError = Mutex<DeviceSessionError?>(nil)

    init(
        wearables: any WearablesInterface = Wearables.shared,
        connection: GlassesConnection? = nil,
        profile: @escaping (Species) -> SpeciesProfile? = { _ in nil },
        image: @escaping (LensImage) -> UIImage? = { _ in nil }
    ) {
        self.wearables = wearables
        self.connection = connection
        self.profile = profile
        self.image = image
        card = LensCardRenderer.render(.listening, stack: CandidateStack(), profile: profile)
    }

    var page: LensPage { machine.page }
    var stack: CandidateStack { machine.stack }

    var isActive: Bool { phase == .starting || phase == .running }

    // MARK: - Lifecycle

    func start() async {
        guard !isActive else { return }
        phase = .starting
        errorMessage = nil
        machine = LensStateMachine()
        savedSightings = []
        inputRecords = []
        refreshCard()
        lastSessionError.withLock { $0 = nil }
        do {
            try await attach()
            phase = .running
        } catch {
            errorMessage = error.localizedDescription
            connection?.noteSessionFailure(error)
            await tearDown()
            phase = .stopped(.failed(error.localizedDescription))
        }
    }

    /// Stops a running session from the phone. A start in progress cannot be interrupted (the screen hides Stop
    /// meanwhile): `start()` would otherwise carry on after the teardown and report its own failure over this stop.
    func stop() async {
        await stop(reason: .phone)
    }

    private func stop(reason: StopReason) async {
        guard phase == .running else { return }
        phase = .stopping
        await tearDown()
        phase = .stopped(reason)
    }

    // MARK: - Stack

    /// The latest candidate stack from the engine (or the fake stack): the pages follow it without moving.
    func update(with stack: CandidateStack) {
        guard machine.update(with: stack) else { return }
        refreshCard()
    }

    private func attach() async throws {
        let selector = AutoDeviceSelector(wearables: wearables) { $0.supportsDisplay() }
        guard await selector.waitForDevice() else { throw StartError.noDisplayGlasses }
        let session = try wearables.createSession(deviceSelector: selector)
        self.session = session
        session.statePublisher.listen { [weak self] state in
            Task { @MainActor in self?.sessionDidChange(to: state) }
        }.store(in: tokens)
        session.errorPublisher.listen { [weak self] error in
            self?.lastSessionError.withLock { $0 = error }
            Task { @MainActor in self?.sessionDidFail(error) }
        }.store(in: tokens)
        try session.start()
        guard await session.waitUntilStarted() else {
            throw StartError.sessionDidNotStart(lastSessionError.withLock { $0 })
        }

        let display = try session.addDisplay()
        self.display = display
        display.statePublisher.listen { [weak self] state in
            Task { @MainActor in self?.displayState = state }
        }.store(in: tokens)
        let displayStarted = await display.statePublisher.waitUntil(timeout: .seconds(15), after: display.start) { state in
            switch state {
            case .started: true
            case .stopped: false
            case .starting, .stopping: nil
            @unknown default: nil
            }
        }
        guard displayStarted else { throw StartError.displayDidNotStart }
        try await display.send(renderedCard())

        // Inputs last: `addInputs` returns nil unless the session is already started.
        guard let inputs = try session.addInputs(configuration: InputsConfiguration(consumeBack: true)) else {
            throw StartError.inputsUnavailable
        }
        inputsCapability = inputs
        inputsState = inputs.state
        inputs.statePublisher.listen { [weak self] state in
            Task { @MainActor in self?.inputsState = state }
        }.store(in: tokens)
        inputs.errorPublisher.listen { [weak self] error in
            Task { @MainActor in self?.errorMessage = "Inputs: \(error.description)" }
        }.store(in: tokens)
        let events = inputs.events
        inputTask = Task { [weak self] in
            for await event in events {
                self?.handle(event)
            }
        }
    }

    /// Releases Inputs, Display and the session, in that order, and every listener token.
    private func tearDown() async {
        inputTask?.cancel()
        inputTask = nil
        savedTask?.cancel()
        savedTask = nil
        sendTask?.cancel()
        sendTask = nil
        await tokens.cancelAll()
        if inputsCapability != nil {
            try? session?.removeInputs()
            inputsCapability = nil
        }
        display?.stop()
        display = nil
        session?.stop()
        session = nil
        inputsState = .inactive
        displayState = .stopped
        sessionState = .stopped
    }

    // MARK: - Events

    private func sessionDidChange(to state: DeviceSessionState) {
        sessionState = state
        // While starting, `start()` reports the failure; while stopping, the phone asked for it.
        guard state == .stopped, phase == .running else { return }
        phase = .stopping // Claimed now, so a Stop tapped meanwhile is a no-op rather than a second teardown.
        // The glasses report their own end as an error too ("Session ended by device", DECISIONS.md doff test);
        // the phase already says so, and only a real failure (thermal, battery) is worth a red line.
        if let error = lastSessionError.withLock({ $0 }), Self.isEndedByDevice(error) {
            errorMessage = nil
        }
        Task {
            await tearDown()
            phase = .stopped(.glasses)
        }
    }

    private func sessionDidFail(_ error: DeviceSessionError) {
        errorMessage = error.description
        connection?.noteSessionFailure(error)
    }

    private static func isEndedByDevice(_ error: DeviceSessionError) -> Bool {
        if case .unexpectedError(let description) = error {
            return description.localizedCaseInsensitiveContains("ended by device")
        }
        return false
    }

    private func handle(_ event: InputEvent) {
        let record = InputRecord(event)
        inputRecords.insert(record, at: 0)
        if inputRecords.count > Self.maxRecords { inputRecords.removeLast(inputRecords.count - Self.maxRecords) }
        guard let gesture = record.gesture else { return }
        perform(machine.apply(gesture))
    }

    /// A click on a card button, delivered by Display rather than Inputs.
    private func buttonClicked(_ button: LensButton) {
        perform(machine.press(button))
    }

    private func perform(_ effect: LensEffect?) {
        switch effect {
        case .saveSighting(let candidate):
            savedSightings.append(candidate)
            savedTask?.cancel()
            savedTask = Task { [weak self, savedDismissDelay] in
                try? await Task.sleep(for: savedDismissDelay)
                guard !Task.isCancelled, let self else { return }
                self.machine.dismissSaved()
                self.refreshCard()
            }
        case .endSession:
            Task { await stop(reason: .back) }
        case nil:
            break
        }
        refreshCard()
    }

    // MARK: - Display

    /// Re-renders the current page and sends it if it changed. Every page shows the stack (count, position, score),
    /// so a stack update on any page can change the card without changing the page.
    private func refreshCard() {
        let next = LensCardRenderer.render(machine.page, stack: machine.stack, profile: profile)
        guard next != card else { return }
        card = next
        resendCard()
    }

    private func renderedCard() -> FlexBox {
        DisplayCardBuilder.flexBox(for: card, image: image) { [weak self] button in
            Task { @MainActor in self?.buttonClicked(button) }
        }
    }

    private func resendCard() {
        guard let display else { return }
        let view = renderedCard()
        let previous = sendTask
        sendTask = Task { [weak self] in
            await previous?.value
            // Only the newest queued send is cancelled by a teardown; older ones find the display gone here.
            guard !Task.isCancelled, let self, self.display === display else { return }
            do {
                try await display.send(view)
            } catch where self.display === display {
                self.errorMessage = "Display: \(error.localizedDescription)"
            } catch {
                // The run ended while sending; the phase already says so.
            }
        }
    }
}

extension GlassesLensSession.InputRecord {
    init(_ event: InputEvent) {
        receivedAt = .now
        switch event {
        case .nav(let direction, let source, _):
            gesture = LensGesture(direction)
            description = "Nav \(direction) · \(source)"
        case .select(let source, _):
            gesture = .tap
            description = "Select · \(source)"
        case .back(let source, _):
            gesture = .back
            description = "Back · \(source)"
        case .button(let button, let source, _):
            gesture = nil
            description = "Button \(button) · \(source) (ignored)"
        case .capture(let press, let source, _):
            gesture = nil
            description = "Capture \(press) · \(source) (ignored)"
        case .drag(let action, _, _, _, _, let source, _):
            gesture = nil
            description = "Drag \(action) · \(source) (ignored)"
        @unknown default:
            gesture = nil
            description = "Unknown input event (ignored)"
        }
    }
}

extension LensGesture {
    /// Swipes arrive as Nav events from the Neural Band (DECISIONS.md, "Lens UI").
    init(_ direction: NavDirection) {
        self = switch direction {
        case .left: .swipeLeft
        case .right: .swipeRight
        case .up: .swipeUp
        case .down: .swipeDown
        }
    }
}

extension LensPage {
    /// The page as the phone screen names it.
    var title: String {
        switch self {
        case .listening: "Listening"
        case .photo(let index): "Photo \(index + 1)"
        case .description(let index): "Description \(index + 1)"
        case .confirm(let index): "Confirm \(index + 1)"
        case .saved(let index): "Saved \(index + 1)"
        }
    }
}
