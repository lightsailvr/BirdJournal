import Album
import Foundation
import Identification
import LensSession
import MWDATCamera
import MWDATCore
import Observation
import OSLog
import SwiftData
import UIKit

/// The whole loop on the glasses (issue #9): one device session shared by the camera stream, Display and Inputs;
/// glasses audio through the engine into the lens pages; "Add to my list" on a species' details page writes the sighting to
/// the album with the most recent camera frame (issue #24). Start from the phone, then pocket it: nothing here needs
/// the screen.
///
/// Order: the device session (which waits for connected display glasses), camera and microphone permission, the
/// lens (so the wearer sees the empty species list while the models load), then the listening session over the stream. The run ends from the phone, from Back on the root,
/// or when the glasses end the session with a quit (two-finger tap); each path tears down the same way.
///
/// The run survives the glasses (issue #10). Taking them off ends the session and drops the link rather than pausing
/// it (DECISIONS.md, phase A), and so does walking out of range, so when the session stops on the device side the run
/// reads the glasses' state to tell a doff from a lost link from a quit: for the first two it suspends the lens and
/// the stream, keeps the engine and the pages, and waits for the glasses to be worn and connected again, then starts
/// a new session under them. A session the toolkit pauses (`.paused`, the touchpad) is shown as paused and resumes
/// with it. No location and a lost link are reported to the wearer on the lens as a problem page with a way back.
@Observable
final class GlassesListeningSession {
    enum Phase: Equatable {
        case idle
        case starting
        case listening
        /// The glasses ended the session; the run is finding out whether the wearer quit or the glasses left.
        case interrupted
        /// Waiting for the glasses to come back, or for the toolkit to resume a session it paused.
        case paused(PauseReason)
        /// The glasses are back: a new session is starting under the lens and the stream.
        case resuming
        case stopping
        case stopped(StopReason)
    }

    enum PauseReason: Equatable {
        /// The wearer took the glasses off.
        case glassesOff
        /// The link dropped: out of range, or Bluetooth off.
        case disconnected
        /// The toolkit paused the session (touchpad); it resumes it too.
        case byGlasses
    }

    /// Why the run ended, recorded the same way on the lens.
    typealias StopReason = GlassesLensSession.StopReason

    enum StartError: LocalizedError {
        case listeningDidNotStart(String)
        case lensDidNotStart(String)

        var errorDescription: String? {
            switch self {
            case .listeningDidNotStart(let message): message
            case .lensDidNotStart(let message): message
            }
        }
    }

    /// How the run tells a quit from an interruption and how hard it tries to get back on the glasses.
    struct ReconnectPolicy: Sendable {
        /// After the glasses end a session while worn and connected, how long to watch them for a doff or a
        /// dropped link (which can be reported a beat after the session stops) before calling it a quit.
        var quitGrace: Duration = .seconds(2)
        /// Session starts to try once the glasses are back before the run gives up.
        var attempts = 3
        var retryDelay: Duration = .seconds(5)

        init() {}
    }

    /// One sighting written this run, as the phone lists it. A species saved again in the same run updates its
    /// sighting rather than adding a second (spec user story 33).
    typealias SavedSighting = RunSightings.Entry

    private static let logger = Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "glasses-listening")

    private(set) var phase: Phase = .idle
    private(set) var sessionState: DeviceSessionState = .idle
    private(set) var streamState: StreamState = .stopped
    var errorMessage: String?
    /// Sightings written this run, in first-save order.
    var saved: [SavedSighting] { sightings.entries }

    /// Engine, location and the live list.
    let listening: ListeningSession
    /// Pages on the lens.
    let lens: GlassesLensSession

    @ObservationIgnored private let wearables: any WearablesInterface
    @ObservationIgnored private let connection: GlassesConnection?
    @ObservationIgnored private let makeSource: (DeviceSession) -> any FrameKeepingAudioSource
    /// The run's sightings, shared with the phone's "Add to journal" (issue #28) so both add each species once.
    let sightings: RunSightings
    @ObservationIgnored private let policy: ReconnectPolicy
    @ObservationIgnored private var session: DeviceSession?
    @ObservationIgnored private var source: (any FrameKeepingAudioSource)?
    @ObservationIgnored private var sourceEventTask: Task<Void, Never>?
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    /// From the glasses ending the session to the run listening again or stopped.
    @ObservationIgnored private var interruptionTask: Task<Void, Never>?
    @ObservationIgnored private let tokens = ListenerTokenBag()
    /// The last error the session published, read when it stops to tell a failure from the glasses' own end.
    @ObservationIgnored private var lastSessionError: DeviceSessionError?

    init(
        wearables: any WearablesInterface = Wearables.shared,
        connection: GlassesConnection? = nil,
        recorder: SightingRecorder,
        sightings: RunSightings? = nil,
        loadEngine: @escaping @Sendable () async throws -> IdentificationEngine = { try await BundledIdentification.engine() },
        makeSource: @escaping (DeviceSession) -> any FrameKeepingAudioSource = { session in
            GlassesAudioSource(lease: .shared(session), sampleRate: .rate44100)
        },
        location: any LocationProvider = CoreLocationProvider(),
        reconnect: ReconnectPolicy = ReconnectPolicy(),
        profile: @escaping (Species) -> SpeciesProfile? = { _ in nil },
        image: @escaping (LensImage) -> UIImage? = { _ in nil },
        suppression: AudioSuppression? = nil
    ) {
        self.wearables = wearables
        self.connection = connection
        self.sightings = sightings ?? RunSightings(recorder: recorder)
        self.makeSource = makeSource
        self.policy = reconnect
        // The closures reach back into the run; both objects live as long as it does.
        let box = WeakBox()
        listening = ListeningSession(
            loadEngine: loadEngine,
            location: location,
            onStack: { stack in
                guard let run = box.run else { return }
                run.lens.update(with: stack, at: run.listening.sessionTime)
            },
            suppression: suppression
        )
        lens = GlassesLensSession(
            wearables: wearables,
            connection: connection,
            profile: profile,
            image: image,
            onEffect: { effect in box.run?.handle(effect) }
        )
        box.run = self
    }

    /// Whether a run is under way, including one waiting for the glasses to come back.
    var isActive: Bool {
        switch phase {
        case .starting, .listening, .interrupted, .paused, .resuming: true
        case .idle, .stopping, .stopped: false
        }
    }

    /// Whether the stream has delivered a frame a save could store.
    var hasCameraFrame: Bool { source?.latestFrame != nil }

    /// The most recent camera frame as a JPEG, encoded off the main actor; nil without a stream or a frame. What
    /// a phone-side add during a glasses run stores as the sighting's snapshot.
    func captureFrame() async -> Data? {
        guard let frame = source?.latestFrame else { return nil }
        return await Task.detached(priority: .userInitiated) { frame.jpegData() }.value
    }

    // MARK: - Lifecycle

    func start() async {
        guard !isActive, phase != .stopping else { return }
        phase = .starting
        errorMessage = nil
        sightings.reset()
        stopTask = nil
        lastSessionError = nil
        do {
            let session = try await startSession()
            try await wearables.ensurePermission(.camera)
            try await wearables.ensurePermission(.microphone)

            await lens.start(lease: .shared(session))
            guard lens.phase == .running else {
                throw StartError.lensDidNotStart(lens.errorMessage ?? "The lens did not start.")
            }

            let source = makeSource(session)
            self.source = source
            if let glasses = source as? GlassesAudioSource {
                sourceEventTask = Task { [weak self] in
                    for await event in glasses.events {
                        if case .streamState(let state) = event { self?.streamState = state }
                    }
                }
            }
            await listening.start(source: source)
            guard listening.phase == .listening else {
                throw StartError.listeningDidNotStart(listening.errorMessage ?? "Listening did not start.")
            }
            // The first fix settled before listening started; without one the wearer should know the list is
            // not filtered by region, and how to fix that.
            switch listening.locationState {
            case .settled(.denied), .settled(.unavailable): lens.report(.noLocation)
            case .unknown, .requesting, .settled(.fix): break
            }
            phase = .listening
        } catch {
            errorMessage = error.localizedDescription
            connection?.noteSessionFailure(error)
            Self.logger.error("start failed: \(error.localizedDescription, privacy: .public)")
            await tearDown()
            phase = .stopped(.failed(error.localizedDescription))
        }
    }

    /// Ends a run from the phone, listening or waiting for the glasses. Ignored while starting (the screen hides
    /// Stop); a stop already under way is awaited.
    func stop() async {
        beginStop(reason: .phone)
        await stopTask?.value
    }

    private func beginStop(reason: StopReason) {
        switch phase {
        case .listening, .interrupted, .paused, .resuming: break
        case .idle, .starting, .stopping, .stopped: return
        }
        phase = .stopping
        stopTask = Task { [self] in
            await tearDown(reason: reason)
            phase = .stopped(reason)
        }
    }

    /// Lens first (Display and Inputs off the session), then the stream and engine, then the session itself. A
    /// reconnection under way is cancelled and cleans up after itself. `reason` is passed on to a lens the run
    /// ends (one that did not end itself on Back).
    private func tearDown(reason: StopReason = .phone) async {
        interruptionTask?.cancel()
        interruptionTask = nil
        await lens.stop(reason: reason)
        await listening.stop()
        sourceEventTask?.cancel()
        sourceEventTask = nil
        source = nil
        await discardSession()
        streamState = .stopped
    }

    /// Starts a session on the connected display glasses with the run listening to it.
    private func startSession() async throws -> DeviceSession {
        let session = try await DeviceSessionLease.startSession(wearables: wearables, listen: listen(to:))
        self.session = session
        sessionState = session.state
        return session
    }

    private func listen(to session: DeviceSession) {
        session.statePublisher.listen { [weak self] state in
            Task { @MainActor in self?.sessionDidChange(to: state) }
        }.store(in: tokens)
        session.errorPublisher.listen { [weak self] error in
            Task { @MainActor in self?.sessionDidFail(error) }
        }.store(in: tokens)
    }

    /// Lets go of the session and its listeners; stopping a session the glasses already ended is harmless.
    private func discardSession() async {
        await tokens.cancelAll()
        session?.stop()
        session = nil
        sessionState = .stopped
    }

    // MARK: - Interruptions

    private func sessionDidChange(to state: DeviceSessionState) {
        sessionState = state
        switch (phase, state) {
        case (.listening, .paused):
            phase = .paused(.byGlasses)
        case (.paused(.byGlasses), .started):
            // The lens re-sends its card itself.
            phase = .listening
        case (.listening, .stopped), (.paused(.byGlasses), .stopped):
            phase = .interrupted
            interruptionTask = Task { [self] in await handleInterruption() }
        default:
            break
        }
    }

    private func sessionDidFail(_ error: DeviceSessionError) {
        lastSessionError = error
        connection?.noteSessionFailure(error)
        if !error.isEndedByDevice { errorMessage = error.description }
    }

    /// The glasses ended the session. The lens and the stream are suspended, then: a failure the glasses cannot
    /// recover from ends the run; glasses that are off or disconnected are waited for; anything else is the wearer
    /// quitting.
    private func handleInterruption() async {
        let ended = session
        await suspendCapabilities()
        guard !Task.isCancelled else { return }

        if let error = lastSessionError, error.endsRun {
            beginStop(reason: .failed(error.description))
            return
        }
        guard let device = ended.flatMap({ wearables.deviceForIdentifier($0.deviceId) }) else {
            beginStop(reason: .glasses)
            return
        }
        guard let reason = await device.firstState(within: policy.quitGrace, PauseReason.whyEnded) else {
            guard !Task.isCancelled else { return }
            beginStop(reason: .glasses)
            return
        }
        guard !Task.isCancelled else { return }
        Self.logger.info("paused: \(String(describing: reason), privacy: .public)")
        phase = .paused(reason)
        await reconnect(after: reason, to: device)
    }

    /// Takes the lens and the stream off a session that ended under them; the pages and the chunk stream stay.
    private func suspendCapabilities() async {
        await lens.suspend()
        await source?.suspend()
        streamState = .stopped
        await discardSession()
    }

    /// Waits for the glasses to be worn and connected, then starts a session under the lens and the stream, a few
    /// times over if need be. Glasses that leave again during the resume are waited for again. Cancelled by a
    /// stop, which tears down whatever this had put up.
    private func reconnect(after reason: PauseReason, to device: Device) async {
        var failures = 0
        while !Task.isCancelled {
            guard await device.firstState(within: nil, { $0.isWornAndConnected ? true : nil }) == true, !Task.isCancelled else { return }
            phase = .resuming
            do {
                try await resumeOnNewSession(after: reason)
                guard !Task.isCancelled else {
                    await lens.stop()
                    await discardSession()
                    return
                }
                guard sessionState == .started else {
                    // Ended under the resume (a second doff): back to waiting.
                    await suspendCapabilities()
                    phase = .paused(reason)
                    continue
                }
                phase = .listening
                return
            } catch {
                Self.logger.error("reconnect failed: \(error.localizedDescription, privacy: .public)")
                await suspendCapabilities()
                guard !Task.isCancelled else { return }
                failures += 1
                if failures >= max(policy.attempts, 1) {
                    let message = "The glasses came back but the session did not restart: \(error.localizedDescription)"
                    errorMessage = message
                    beginStop(reason: .failed(message))
                    return
                }
                phase = .paused(reason)
                try? await Task.sleep(for: policy.retryDelay)
            }
        }
    }

    private func resumeOnNewSession(after reason: PauseReason) async throws {
        let session = try await startSession()
        // A lost link is worth a word on the lens; a doff is what the wearer did themselves.
        if reason == .disconnected { lens.report(.connectionLost) }
        await lens.resume(lease: .shared(session))
        guard lens.phase == .running else {
            throw StartError.lensDidNotStart(lens.errorMessage ?? "The lens did not resume.")
        }
        guard let source else { throw StartError.listeningDidNotStart("The audio source is gone.") }
        try await source.resume(on: session)
    }

    // MARK: - Effects

    private func handle(_ effect: LensEffect) {
        switch effect {
        case .saveSighting(let candidate):
            // The frame is taken now, at the tap, so the sighting shows what the wearer was looking at; it is
            // encoded off the main actor.
            let frame = source?.latestFrame
            let confirmedAt = Date.now
            Task {
                let jpeg = await Task.detached(priority: .userInitiated) { frame?.jpegData() }.value
                await save(candidate, confirmedAt: confirmedAt, frame: jpeg)
            }
        case .endSession:
            beginStop(reason: .back)
        case .playSound, .stopSound:
            // The lens plays its clips itself, through the shared player.
            break
        }
    }

    /// Writes the sighting; the run's ledger keeps the album clean (spec user story 33) should the same species
    /// arrive again.
    private func save(_ candidate: Candidate, confirmedAt: Date, frame: Data?) async {
        do {
            try sightings.add(candidate, confirmedAt: confirmedAt, location: listening.coordinate, frame: frame, source: .glasses)
        } catch {
            errorMessage = "Could not save the sighting: \(error.localizedDescription)"
            Self.logger.error("save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension GlassesListeningSession.PauseReason {
    /// Why glasses in `state` would have ended a session, or nil when they are worn and connected (a quit).
    nonisolated static func whyEnded(_ state: DeviceState) -> Self? {
        if state.donState == .doffed {
            .glassesOff
        } else if state.linkState != .connected {
            .disconnected
        } else {
            nil
        }
    }
}

extension DeviceState {
    /// Connected and not known to be off the wearer's face: a session can be started.
    nonisolated var isWornAndConnected: Bool { linkState == .connected && donState != .doffed }
}

/// Lets the run's children call back into it without a retain cycle through their closures.
private final class WeakBox {
    weak var run: GlassesListeningSession?
}
