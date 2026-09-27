import Foundation
import Identification
import LensSession
import MWDATCore
import MWDATDisplay
import MWDATInputs
import Observation
import Synchronization
import UIKit

/// The glasses adapter for the lens (spec "Glasses adapter"): a device session with Display and Inputs attached,
/// the `LensStateMachine` fed with stack updates, every Nav, Select and Back the glasses deliver, and every tap on
/// a card element the Display reports, and the card it lands on rendered onto the lens after each change. Saves are
/// handed to `onEffect` for the listening run to act on (issue #9); Back on the root ends the run here.
///
/// Order (DAT-SETUP-CHECKLIST.md): Display attaches once the session is `.started`, the first card is sent once
/// Display is `.started`, and Inputs attaches last, with `consumeBack` so a Back event reaches the app when
/// hardware delivers one. Real Display glasses end the session themselves on the two-finger tap, which arrives
/// as `.stopped` and is reported as `StopReason.glasses`. Each `start` begins a fresh page state on the session its
/// lease gives: one of its own, or the listening run's, shared with the camera stream.
///
/// A shared session the glasses end (a doff ends the session and drops the link, DECISIONS.md phase A) suspends
/// the adapter instead of stopping it (issue #10): Display and Inputs are released, the pages stay as the wearer
/// left them, and the run either resumes them on its next session or stops. A problem the run reports (no
/// location, a lost link) covers the current page until the wearer swipes right.
@Observable
final class GlassesLensSession {
    enum Phase: Equatable {
        case idle
        case starting
        case running
        /// The run's session ended under the pages; they wait for `resume(lease:)` or `stop()`.
        case suspended
        case stopping
        case stopped(StopReason)
    }

    enum StopReason: Equatable {
        /// Stop was tapped on the phone.
        case phone
        /// Back on the species list (the root) ended the session.
        case back
        /// The session ended on the device side (two-finger tap, doff, link loss).
        case glasses
        case failed(String)
    }

    enum StartError: LocalizedError {
        case displayDidNotStart
        case inputsUnavailable

        var errorDescription: String? {
            switch self {
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
    /// Candidates saved this run, newest last; the listening run writes them to the album.
    private(set) var savedSightings: [Candidate] = []
    /// Newest first, capped at `maxRecords`.
    private(set) var inputRecords: [InputRecord] = []
    var errorMessage: String?

    @ObservationIgnored private let wearables: any WearablesInterface
    @ObservationIgnored private let connection: GlassesConnection?
    /// Pack lookup for the species cards.
    @ObservationIgnored private let profile: (Species) -> SpeciesProfile?
    /// Pixels for the images the pack names.
    @ObservationIgnored private let image: (LensImage) -> UIImage?
    /// Told about saves; ending the session on Back is handled here.
    @ObservationIgnored private let onEffect: (LensEffect) -> Void
    /// How close two saves of one species must be to count as one press delivered twice.
    @ObservationIgnored private let saveDebounce: Duration
    @ObservationIgnored private var lastSave: (species: Species, at: ContinuousClock.Instant)?
    @ObservationIgnored private var lease: DeviceSessionLease = .own
    @ObservationIgnored private var session: DeviceSession?
    @ObservationIgnored private var display: Display?
    @ObservationIgnored private var inputsCapability: Inputs?
    @ObservationIgnored private var inputTask: Task<Void, Never>?
    /// The teardown in progress (a stop or a suspension), so a stop or resume that lands meanwhile awaits it.
    @ObservationIgnored private var teardownTask: Task<Void, Never>?
    /// Sends run one after another so a burst of gestures leaves the latest card on the lens.
    @ObservationIgnored private var sendTask: Task<Void, Never>?
    @ObservationIgnored private let tokens = ListenerTokenBag()
    /// Written straight from the toolkit callback, so the end of a run can tell a device-side end from a failure.
    @ObservationIgnored private nonisolated let lastSessionError = Mutex<DeviceSessionError?>(nil)

    init(
        wearables: any WearablesInterface = Wearables.shared,
        connection: GlassesConnection? = nil,
        profile: @escaping (Species) -> SpeciesProfile? = { _ in nil },
        image: @escaping (LensImage) -> UIImage? = { _ in nil },
        saveDebounce: Duration = .seconds(1),
        onEffect: @escaping (LensEffect) -> Void = { _ in }
    ) {
        self.wearables = wearables
        self.connection = connection
        self.profile = profile
        self.image = image
        self.saveDebounce = saveDebounce
        self.onEffect = onEffect
        card = LensCardRenderer.render(.list, stack: CandidateStack(), selection: 0, saved: [], profile: profile)
    }

    var page: LensPage { machine.page }
    var stack: CandidateStack { machine.stack }

    /// Whether the adapter holds a run's pages: starting, on the lens, or waiting for the run's session to return.
    var isActive: Bool { phase == .starting || phase == .running || phase == .suspended }

    // MARK: - Lifecycle

    /// Puts the pages on the lens over the session `lease` gives.
    func start(lease: DeviceSessionLease = .own) async {
        guard !isActive else { return }
        phase = .starting
        errorMessage = nil
        self.lease = lease
        machine = LensStateMachine()
        savedSightings = []
        lastSave = nil
        inputRecords = []
        teardownTask = nil
        refreshCard()
        await attachOrFail()
    }

    /// Puts the pages back on the lens over the session `lease` gives, after the run's session ended under them:
    /// the page, the selection and the saved marks are as the wearer left them, and a problem reported meanwhile
    /// is the first card sent. Only from `.suspended`; a stop that landed first wins.
    func resume(lease: DeviceSessionLease) async {
        guard phase == .suspended else { return }
        await teardownTask?.value
        guard phase == .suspended else { return }
        phase = .starting
        errorMessage = nil
        self.lease = lease
        await attachOrFail()
    }

    private func attachOrFail() async {
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

    /// Stops a running or suspended session from the phone. A start in progress cannot be interrupted (the screen
    /// hides Stop meanwhile): `start()` would otherwise carry on after the teardown and report its own failure over
    /// this stop. A stop already under way (Back, the glasses) is awaited instead and keeps its reason.
    func stop() async {
        await stop(reason: .phone)
    }

    /// As `stop()`, recorded with `reason`: the run passes on why it ended a suspended lens.
    func stop(reason: StopReason) async {
        switch phase {
        case .running:
            beginStop(reason: reason)
        case .suspended:
            // Everything was released on suspension; only the phase is left to settle once that teardown is done.
            phase = .stopping
            let suspension = teardownTask
            teardownTask = Task { [self] in
                await suspension?.value
                phase = .stopped(reason)
            }
        case .idle, .starting, .stopping, .stopped:
            break
        }
        await teardownTask?.value
    }

    private func beginStop(reason: StopReason) {
        guard phase == .running else { return }
        phase = .stopping
        teardownTask = Task { [self] in
            await tearDown()
            phase = .stopped(reason)
        }
    }

    /// Takes the pages off a shared session that ended under them and keeps them for `resume(lease:)`. The run
    /// calls this when it learns the session ended; the adapter also does it on the session's own `.stopped`, so
    /// whichever arrives first suspends and the other finds it done. Returns once everything is released.
    func suspend() async {
        guard !lease.isOwned else { return }
        beginSuspend()
        await teardownTask?.value
    }

    /// The shared session ended under the pages: release what was on it and keep the pages for `resume(lease:)`.
    private func beginSuspend() {
        guard phase == .running else { return }
        phase = .suspended
        teardownTask = Task { [self] in
            await tearDown()
        }
    }

    // MARK: - Problems

    /// Shows `problem` over the current page until the wearer swipes right (or taps, or goes back). Sent at once
    /// when the lens is up, or as the first card when the pages resume.
    func report(_ problem: LensProblem) {
        machine.report(problem)
        refreshCard()
    }


    // MARK: - Stack

    /// The latest candidate stack from the engine (or the fake stack): the pages follow it without moving.
    func update(with stack: CandidateStack) {
        guard machine.update(with: stack) else { return }
        refreshCard()
    }

    private func attach() async throws {
        let session = try await lease.session(wearables: wearables) { session in
            session.statePublisher.listen { [weak self] state in
                Task { @MainActor in self?.sessionDidChange(to: state) }
            }.store(in: tokens)
            session.errorPublisher.listen { [weak self] error in
                self?.lastSessionError.withLock { $0 = error }
                Task { @MainActor in self?.sessionDidFail(error) }
            }.store(in: tokens)
        }
        self.session = session

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

    /// Releases Inputs, Display and (when it is this adapter's own) the session, in that order, and every listener
    /// token. A shared session is left to its owner. The capabilities are taken off the adapter before the first
    /// await, so a card refreshed meanwhile finds no display to send to.
    private func tearDown() async {
        inputTask?.cancel()
        inputTask = nil
        sendTask?.cancel()
        sendTask = nil
        let display = self.display
        self.display = nil
        let inputs = inputsCapability
        inputsCapability = nil
        let session = self.session
        self.session = nil
        await tokens.cancelAll()
        if inputs != nil {
            try? session?.removeInputs()
        }
        display?.stop()
        if lease.isOwned {
            session?.stop()
            sessionState = .stopped
        }
        inputsState = .inactive
        displayState = .stopped
    }

    // MARK: - Events

    private func sessionDidChange(to state: DeviceSessionState) {
        let previous = sessionState
        sessionState = state
        // While starting, `start()` reports the failure; while stopping, the phone asked for it.
        guard phase == .running else { return }
        switch state {
        case .started where previous == .paused:
            // The glasses paused the session (touchpad) and resumed it; the display may have dropped the card.
            resendCard()
        case .stopped:
            // The glasses report their own end as an error too ("Session ended by device", DECISIONS.md doff test);
            // the phase already says so, and only a real failure (thermal, battery) is worth a red line.
            if lastSessionError.withLock({ $0 })?.isEndedByDevice == true {
                errorMessage = nil
            }
            // Claimed now, so a Stop tapped meanwhile awaits this teardown instead of repeating it. The run that
            // owns a shared session decides whether its pages come back (doff, link loss) or it is over (a quit).
            if lease.isOwned {
                beginStop(reason: .glasses)
            } else {
                beginSuspend()
            }
        case .idle, .starting, .started, .paused, .stopping:
            break
        }
    }

    private func sessionDidFail(_ error: DeviceSessionError) {
        errorMessage = error.description
        connection?.noteSessionFailure(error)
    }

    private func handle(_ event: InputEvent) {
        let record = InputRecord(event)
        inputRecords.insert(record, at: 0)
        if inputRecords.count > Self.maxRecords { inputRecords.removeLast(inputRecords.count - Self.maxRecords) }
        // Events that land while the run is ending (after Back on the root, say) must not move the pages.
        guard let gesture = record.gesture, phase == .running else { return }
        perform(machine.apply(gesture))
    }

    /// A tap on a card element (the Save button), delivered by Display rather than Inputs.
    private func tapped(_ action: LensAction) {
        guard phase == .running else { return }
        perform(machine.press(action))
    }

    private func perform(_ effect: LensEffect?) {
        switch effect {
        case .saveSighting(let candidate):
            // Hardware may deliver one press as both a button click and an Inputs select (DECISIONS.md, "Lens UI"):
            // a second save of the same species inside `saveDebounce` is that echo, not a wish to save again.
            let now = ContinuousClock.now
            if let lastSave, lastSave.species == candidate.species, now - lastSave.at < saveDebounce {
                break
            }
            lastSave = (candidate.species, now)
            savedSightings.append(candidate)
            onEffect(.saveSighting(candidate))
        case .endSession:
            beginStop(reason: .back)
            onEffect(.endSession)
        case nil:
            break
        }
        refreshCard()
    }

    // MARK: - Display

    /// Re-renders the current page and sends it if it changed. Every page shows the stack (count, position, score),
    /// so a stack update on any page can change the card without changing the page.
    private func refreshCard() {
        let next = LensCardRenderer.render(machine.page, stack: machine.stack, selection: machine.selection, saved: machine.savedIndices, profile: profile)
        guard next != card else { return }
        card = next
        resendCard()
    }

    private func renderedCard() -> FlexBox {
        DisplayCardBuilder.flexBox(for: card, image: image) { [weak self] action in
            Task { @MainActor in self?.tapped(action) }
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
