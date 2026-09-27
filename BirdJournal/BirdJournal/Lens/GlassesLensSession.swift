import Foundation
import LensSession
import MWDATCore
import MWDATDisplay
import MWDATInputs
import Observation
import Synchronization

/// Phase A lens round trip (issue #4): one device session with Display and Inputs attached, one card on the
/// lens, and every Nav and Select the glasses deliver echoed to the phone and back onto the card.
///
/// Order (DAT-SETUP-CHECKLIST.md): Display attaches once the session is `.started`, the first card is sent once
/// Display is `.started`, and Inputs attaches last, with `consumeBack` so a Back event reaches the app when
/// hardware delivers one. Real Display glasses end the session themselves on the two-finger tap, which arrives
/// as `.stopped` and is reported as `StopReason.glasses`. Single use per run: `start` resets the echo.
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
        /// The gesture it maps to, or nil for events the lens ignores (Back, buttons, capture, drag).
        let gesture: LensGesture?
    }

    static let maxRecords = 100

    private(set) var phase: Phase = .idle
    private(set) var sessionState: DeviceSessionState = .idle
    private(set) var displayState: DisplayState = .stopped
    private(set) var inputsState: InputsState = .inactive
    private(set) var echo = GestureEcho()
    /// Newest first, capped at `maxRecords`.
    private(set) var inputs: [InputRecord] = []
    /// Clicks of the card's button, delivered by Display rather than Inputs.
    private(set) var buttonClicks = 0
    var errorMessage: String?

    @ObservationIgnored private let wearables: any WearablesInterface
    @ObservationIgnored private let connection: GlassesConnection?
    @ObservationIgnored private var session: DeviceSession?
    @ObservationIgnored private var display: Display?
    @ObservationIgnored private var inputsCapability: Inputs?
    @ObservationIgnored private var inputTask: Task<Void, Never>?
    /// Sends run one after another so a burst of gestures leaves the latest card on the lens.
    @ObservationIgnored private var sendTask: Task<Void, Never>?
    @ObservationIgnored private let tokens = ListenerTokenBag()
    /// Written straight from the toolkit callback, so a failed start can report it without waiting for a hop.
    @ObservationIgnored private nonisolated let lastSessionError = Mutex<DeviceSessionError?>(nil)

    init(wearables: any WearablesInterface = Wearables.shared, connection: GlassesConnection? = nil) {
        self.wearables = wearables
        self.connection = connection
    }

    var card: LensCard { echo.card }

    var isActive: Bool { phase == .starting || phase == .running }

    // MARK: - Lifecycle

    func start() async {
        guard !isActive else { return }
        phase = .starting
        errorMessage = nil
        echo = GestureEcho()
        inputs = []
        buttonClicks = 0
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

    func stop() async {
        guard isActive else { return }
        phase = .stopping
        await tearDown()
        phase = .stopped(.phone)
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
        async let displayStarted = display.statePublisher.waitUntil(timeout: .seconds(15)) { state in
            switch state {
            case .started: true
            case .stopped: false
            case .starting, .stopping: nil
            @unknown default: nil
            }
        }
        display.start()
        guard await displayStarted else { throw StartError.displayDidNotStart }
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
        Task {
            await tearDown()
            phase = .stopped(.glasses)
        }
    }

    private func sessionDidFail(_ error: DeviceSessionError) {
        errorMessage = error.description
        connection?.noteSessionFailure(error)
    }

    private func handle(_ event: InputEvent) {
        let gesture: LensGesture? = switch event {
        case .nav(let direction, _, _): LensGesture(direction)
        case .select: .tap
        case .back, .button, .capture, .drag: nil
        @unknown default: nil
        }
        inputs.insert(InputRecord(receivedAt: .now, description: Self.describe(event), gesture: gesture), at: 0)
        if inputs.count > Self.maxRecords { inputs.removeLast(inputs.count - Self.maxRecords) }
        guard let gesture else { return }
        echo.apply(gesture)
        resendCard()
    }

    private func buttonClicked() {
        buttonClicks += 1
    }

    // MARK: - Display

    private func renderedCard() -> FlexBox {
        LensCardRenderer.render(card) { [weak self] in
            Task { @MainActor in self?.buttonClicked() }
        }
    }

    private func resendCard() {
        guard let display else { return }
        let view = renderedCard()
        let previous = sendTask
        sendTask = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                try await display.send(view)
            } catch {
                self?.errorMessage = "Display: \(error.localizedDescription)"
            }
        }
    }

    private static func describe(_ event: InputEvent) -> String {
        switch event {
        case .nav(let direction, let source, _): "Nav \(direction) · \(source)"
        case .select(let source, _): "Select · \(source)"
        case .back(let source, _): "Back · \(source) (ignored)"
        case .button(let button, let source, _): "Button \(button) · \(source) (ignored)"
        case .capture(let press, let source, _): "Capture \(press) · \(source) (ignored)"
        case .drag(let action, _, _, _, _, let source, _): "Drag \(action) · \(source) (ignored)"
        @unknown default: "Unknown input event (ignored)"
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
