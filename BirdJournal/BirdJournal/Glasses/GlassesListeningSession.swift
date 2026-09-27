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
/// glasses audio through the engine into the lens pages; a tap on a photo captures the most recent camera frame;
/// Save writes the sighting to the album. Start from the phone, then pocket it: nothing here needs the screen.
///
/// Order: the device session (which waits for connected display glasses), camera and microphone permission, the
/// lens (so the wearer sees "Listening" while the models load), then the listening session over the stream. The run ends from the phone, from Back on the root,
/// or when the glasses end the session (two-finger tap, doff, link loss); each path tears down the same way.
@Observable
final class GlassesListeningSession {
    enum Phase: Equatable {
        case idle
        case starting
        case listening
        case stopping
        case stopped(StopReason)
    }

    enum StopReason: Equatable {
        case phone
        case back
        case glasses
        case failed(String)
    }

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

    /// One sighting written this run, as the phone lists it. A species saved again in the same run updates its
    /// sighting rather than adding a second (spec user story 33).
    struct SavedSighting: Identifiable, Equatable {
        let id: PersistentIdentifier
        var candidate: Candidate
        var hasFrame: Bool
    }

    /// A tap on a photo page: the frame taken then, encoding off the main actor while the wearer reads the confirm page.
    private struct PendingConfirmation {
        let candidate: Candidate
        let at: Date
        let frame: Task<Data?, Never>
    }

    private static let logger = Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "glasses-listening")

    private(set) var phase: Phase = .idle
    private(set) var sessionState: DeviceSessionState = .idle
    private(set) var streamState: StreamState = .stopped
    /// Sightings written this run, in first-save order.
    private(set) var saved: [SavedSighting] = []
    var errorMessage: String?

    /// Engine, location and the live list.
    let listening: ListeningSession
    /// Pages on the lens.
    let lens: GlassesLensSession

    @ObservationIgnored private let wearables: any WearablesInterface
    @ObservationIgnored private let connection: GlassesConnection?
    @ObservationIgnored private let makeSource: (DeviceSession) -> any FrameKeepingAudioSource
    @ObservationIgnored private let recorder: SightingRecorder
    @ObservationIgnored private var session: DeviceSession?
    @ObservationIgnored private var source: (any FrameKeepingAudioSource)?
    @ObservationIgnored private var sourceEventTask: Task<Void, Never>?
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private let tokens = ListenerTokenBag()
    @ObservationIgnored private var confirmed: PendingConfirmation?
    /// The album records behind `saved`, by species, so a repeat save updates instead of inserting.
    @ObservationIgnored private var sightings: [Species: Sighting] = [:]

    init(
        wearables: any WearablesInterface = Wearables.shared,
        connection: GlassesConnection? = nil,
        recorder: SightingRecorder,
        loadEngine: @escaping @Sendable () async throws -> IdentificationEngine = { try await BundledIdentification.engine() },
        makeSource: @escaping (DeviceSession) -> any FrameKeepingAudioSource = { session in
            GlassesAudioSource(lease: .shared(session), sampleRate: .rate44100)
        },
        location: any LocationProvider = CoreLocationProvider(),
        locationRefreshInterval: Duration = ListeningSession.locationRefreshInterval,
        profile: @escaping (Species) -> SpeciesProfile? = { _ in nil },
        image: @escaping (LensImage) -> UIImage? = { _ in nil },
        savedDismissDelay: Duration = .seconds(2)
    ) {
        self.wearables = wearables
        self.connection = connection
        self.recorder = recorder
        self.makeSource = makeSource
        // The closures reach back into the run; both objects live as long as it does.
        let box = WeakBox()
        listening = ListeningSession(
            loadEngine: loadEngine,
            location: location,
            locationRefreshInterval: locationRefreshInterval,
            onStack: { stack in box.run?.lens.update(with: stack) }
        )
        lens = GlassesLensSession(
            wearables: wearables,
            connection: connection,
            profile: profile,
            image: image,
            savedDismissDelay: savedDismissDelay,
            onEffect: { effect in box.run?.handle(effect) }
        )
        box.run = self
    }

    var isActive: Bool { phase == .starting || phase == .listening }

    /// Whether the stream has delivered a frame a confirm could store.
    var hasCameraFrame: Bool { source?.latestFrame != nil }

    // MARK: - Lifecycle

    func start() async {
        guard !isActive, phase != .stopping else { return }
        phase = .starting
        errorMessage = nil
        saved = []
        sightings = [:]
        confirmed = nil
        stopTask = nil
        do {
            let session = try await DeviceSessionLease.startSession(wearables: wearables) { session in
                session.statePublisher.listen { [weak self] state in
                    Task { @MainActor in self?.sessionDidChange(to: state) }
                }.store(in: tokens)
                session.errorPublisher.listen { [weak self] error in
                    Task { @MainActor in self?.sessionDidFail(error) }
                }.store(in: tokens)
            }
            self.session = session
            sessionState = session.state
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
            phase = .listening
        } catch {
            errorMessage = error.localizedDescription
            connection?.noteSessionFailure(error)
            Self.logger.error("start failed: \(error.localizedDescription, privacy: .public)")
            await tearDown()
            phase = .stopped(.failed(error.localizedDescription))
        }
    }

    /// Ends a run from the phone. Ignored while starting (the screen hides Stop); a stop already under way is awaited.
    func stop() async {
        beginStop(reason: .phone)
        await stopTask?.value
    }

    private func beginStop(reason: StopReason) {
        guard phase == .listening else { return }
        phase = .stopping
        stopTask = Task { [self] in
            await tearDown()
            phase = .stopped(reason)
        }
    }

    /// Lens first (Display and Inputs off the session), then the stream and engine, then the session itself.
    private func tearDown() async {
        await lens.stop()
        await listening.stop()
        sourceEventTask?.cancel()
        sourceEventTask = nil
        source = nil
        await tokens.cancelAll()
        session?.stop()
        session = nil
        sessionState = .stopped
        streamState = .stopped
        confirmed = nil
    }

    // MARK: - Events

    private func sessionDidChange(to state: DeviceSessionState) {
        sessionState = state
        guard state == .stopped, phase == .listening else { return }
        beginStop(reason: .glasses)
    }

    private func sessionDidFail(_ error: DeviceSessionError) {
        connection?.noteSessionFailure(error)
        if !error.isEndedByDevice { errorMessage = error.description }
    }

    private func handle(_ effect: LensEffect) {
        switch effect {
        case .confirmed(let candidate):
            // The frame is taken now, before Save, so the sighting shows what the wearer was looking at.
            let frame = source?.latestFrame
            confirmed = PendingConfirmation(candidate: candidate, at: .now, frame: Task.detached(priority: .userInitiated) { frame?.jpegData() })
        case .saveSighting(let candidate):
            Task { await save(candidate) }
        case .endSession:
            beginStop(reason: .back)
        }
    }

    private func save(_ candidate: Candidate) async {
        let pending = confirmed?.candidate.species == candidate.species ? confirmed : nil
        confirmed = nil
        let frame = await pending?.frame.value
        do {
            if let existing = sightings[candidate.species], let position = saved.firstIndex(where: { $0.id == existing.persistentModelID }) {
                try recorder.update(existing, with: candidate, frame: frame)
                saved[position].candidate = candidate
                if frame != nil { saved[position].hasFrame = true }
            } else {
                let sighting = try recorder.record(
                    candidate,
                    confirmedAt: pending?.at ?? .now,
                    location: listening.coordinate,
                    frame: frame,
                    source: .glasses
                )
                sightings[candidate.species] = sighting
                saved.append(SavedSighting(id: sighting.persistentModelID, candidate: candidate, hasFrame: frame != nil))
            }
        } catch {
            errorMessage = "Could not save the sighting: \(error.localizedDescription)"
            Self.logger.error("save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Lets the run's children call back into it without a retain cycle through their closures.
private final class WeakBox {
    weak var run: GlassesListeningSession?
}
