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
/// glasses audio through the engine into the lens pages; "Add to my list" on a species' details page opens the
/// viewfinder on the camera's frames, and a tap there writes the sighting with a photo taken then (the latest frame if
/// the photo does not come), a swipe without one. "Capture a sighting" on the species list (issue #193) opens a
/// viewfinder for a bird that was seen and not heard: a tap there writes the photo as an unnamed sighting, which the phone
/// lists under "Seen this run" and names. Landing on the species list and opening the viewfinder check that
/// the stream is up and put it back if not (#46). Start from the phone, then pocket it: nothing here needs the screen.
///
/// The photo can be named on the lens too (issue #194). Once it is written the run asks the lens for the bird's name,
/// if it has the names to match against and the glasses' microphone permission (checked silently: without it the lens
/// goes straight to "Photo saved. Name it on your phone." and `dictationNeedsPermission` has the phone offer to turn it
/// on). What the lens hears is matched against the names with the naming sheet's ranking (`NameableBirds.spoken`), over
/// the birds this run has heard and those likely where and when the photo was taken; a tap on a bird names the unnamed
/// sighting through the run's ledger, as the phone would, and a patch it sews waits for its stitch-in on the phone as a
/// lens add's does. While the glasses listen, the camera stream stays on or comes off by `DictationSettings`.
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

    /// One sighting written this run, as the phone lists it; a species saved again is another sighting.
    typealias SavedSighting = RunSightings.Entry

    private static let logger = Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "glasses-listening")

    private(set) var phase: Phase = .idle
    private(set) var sessionState: DeviceSessionState = .idle
    private(set) var streamState: StreamState = .stopped
    var errorMessage: String?
    /// Sightings written this run, in save order.
    var saved: [SavedSighting] { sightings.entries }
    /// Hears the identifier of each sighting that sewed a patch from the lens: its ceremony is for the phone, once the run is over.
    @ObservationIgnored var onPatchSewn: ((UUID) -> Void)?
    /// Hears each photo captured from the lens once it is written as an unnamed sighting (issue #193): the run's ledger
    /// already lists it; the phone writes down a review that is waiting.
    @ObservationIgnored var onCaptured: ((UnnamedSighting) -> Void)?
    /// A photo was taken on the lens and its name could not be asked for, because the glasses' microphone permission is
    /// not granted (issue #194): the phone offers to turn dictation on (`allowDictation()`).
    private(set) var dictationNeedsPermission = false

    /// Engine, location and the live list.
    let listening: ListeningSession
    /// Pages on the lens.
    let lens: GlassesLensSession

    @ObservationIgnored private let wearables: any WearablesInterface
    @ObservationIgnored private let connection: GlassesConnection?
    @ObservationIgnored private let makeSource: (DeviceSession) -> any FrameKeepingAudioSource
    /// The run's sightings, shared with the phone's "Add to collection" (issue #28) so both add each species once.
    let sightings: RunSightings
    @ObservationIgnored private let policy: ReconnectPolicy
    /// The names a photo can be given, read once and off the main actor; nil on a run whose lens never asks for a name.
    @ObservationIgnored private let loadNames: (@Sendable () async -> NameableBirds?)?
    @ObservationIgnored private var namesTask: Task<NameableBirds?, Never>?
    /// Where the birds likely at a photo's place and week are read from.
    @ObservationIgnored private let occurrenceModel: any SpeciesOccurrenceModel
    /// Whether the camera stream stays on while the glasses listen for a name, read as each dictation starts.
    @ObservationIgnored private let dictationKeepsStream: () -> Bool
    /// The stream a dictation took off, until the dictation is over.
    @ObservationIgnored private var dictationHold: (any DictationStreamHold)?
    /// The photos taken on the lens this run that have no name yet, by the lens's number for each.
    @ObservationIgnored private var captured: [Int: UnnamedSighting] = [:]
    /// The birds last offered for each of them, by scientific name: what a tap on the lens names.
    @ObservationIgnored private var offered: [Int: [String: NameableBird]] = [:]
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
        suppression: AudioSuppression? = nil,
        names: (@Sendable () async -> NameableBirds?)? = nil,
        occurrenceModel: any SpeciesOccurrenceModel = BundledIdentification.geoModel,
        dictationLimits: GlassesDictation.Limits = GlassesDictation.Limits(),
        dictationKeepsStream: @escaping () -> Bool = { DictationSettings.keepsStream() }
    ) {
        self.wearables = wearables
        self.connection = connection
        self.sightings = sightings ?? RunSightings(recorder: recorder)
        self.makeSource = makeSource
        self.policy = reconnect
        loadNames = names
        self.occurrenceModel = occurrenceModel
        self.dictationKeepsStream = dictationKeepsStream
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
            dictationLimits: dictationLimits,
            onEffect: { effect in box.run?.handle(effect) }
        )
        if names != nil {
            lens.names = LensNameSource(
                matches: { words, capture in await box.run?.birds(named: words, forCapture: capture) ?? [] },
                name: { capture, match in box.run?.name(capture, as: match) },
                willListen: { await box.run?.dictationWillListen() },
                didListen: { box.run?.dictationDidListen() }
            )
        }
        lens.viewfinderFrame = { box.run?.source?.latestFrame }
        lens.onStreamNeeded = { reason in
            Task { await box.run?.source?.ensureStreaming(reason) }
        }
        lens.onCapture = { id in box.run?.capture(id) }
        box.run = self
    }

    /// Whether a run is under way, including one waiting for the glasses to come back.
    var isActive: Bool {
        switch phase {
        case .starting, .listening, .interrupted, .paused, .resuming: true
        case .idle, .stopping, .stopped: false
        }
    }

    /// The stream a reference clip holds while it plays, so the glasses' speakers play it; nil without a run.
    var playbackStreamHold: (any PlaybackStreamHold)? {
        isActive ? source as? any PlaybackStreamHold : nil
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
        captured = [:]
        offered = [:]
        dictationNeedsPermission = false
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
        case .takePhoto(let candidate):
            // The photo is taken now, at the tap on the viewfinder. Should none come, the frame from this moment
            // stands in, so the sighting still shows what the wearer framed; it is encoded off the main actor.
            let frame = source?.latestFrame
            let confirmedAt = Date.now
            Task {
                var jpeg = await source?.capturePhoto()
                if jpeg == nil {
                    jpeg = await Task.detached(priority: .userInitiated) { frame?.jpegData() }.value
                }
                await save(candidate, confirmedAt: confirmedAt, frame: jpeg)
            }
        case .saveSighting(let candidate):
            // Swiped off the viewfinder: added without a photo.
            let confirmedAt = Date.now
            Task { await save(candidate, confirmedAt: confirmedAt, frame: nil) }
        case .endSession:
            beginStop(reason: .back)
        case .openViewfinder, .openCaptureViewfinder, .playSound, .stopSound:
            // The lens shows its viewfinders and plays its clips itself.
            break
        case .capturePhoto, .listenForName, .nameCapture:
            // The lens asks for a capture's photo through `onCapture`, with a number to answer by, and for the birds a
            // name may be and the naming itself through its `names`.
            break
        }
    }

    /// The tap on the capture viewfinder (issue #193): the photo is taken now and written as an unnamed sighting, with
    /// this moment and the run's place, for the phone to name. As for an add, the frame from the tap stands in if no
    /// photo comes; with neither there is nothing to keep, and the lens says so. The lens is told how capture `id` went.
    private func capture(_ id: Int) {
        let frame = source?.latestFrame
        let takenAt = Date.now
        let location = listening.coordinate
        Task {
            var jpeg = await source?.capturePhoto()
            if jpeg == nil {
                jpeg = await Task.detached(priority: .userInitiated) { frame?.jpegData() }.value
            }
            guard let jpeg else {
                Self.logger.info("capture \(id): no photo and no frame")
                lens.captureFailed(id)
                return
            }
            do {
                let unnamed = try sightings.capture(photo: jpeg, takenAt: takenAt, location: location, source: .glasses)
                onCaptured?(unnamed)
                // The photo is safe from here on: whatever goes wrong after this, the phone has it. The lens asks for
                // the bird's name if the glasses can hear one (issue #194), else says the photo waits on the phone.
                captured[id] = unnamed
                let askName = await canAskName()
                let picture = askName ? await Task.detached(priority: .userInitiated) { DisplayCardBuilder.capturedPhotoImage(jpeg) }.value : nil
                lens.captureSaved(id, askName: askName, photo: picture)
            } catch {
                errorMessage = "Could not save the photo: \(error.localizedDescription)"
                Self.logger.error("capture failed: \(error.localizedDescription, privacy: .public)")
                lens.captureFailed(id)
            }
        }
    }

    // MARK: - Saying the bird's name (issue #194)

    /// Whether the lens can ask for a bird's name now: the run has the names, and the glasses' microphone permission is
    /// granted. The permission is only read here, never asked for: asking opens Meta AI, which is for the phone to offer
    /// (`allowDictation()`), not for a wearer with the phone in a pocket.
    private func canAskName() async -> Bool {
        guard loadNames != nil, phase == .listening else { return false }
        guard let status = try? await wearables.checkPermissionStatus(.microphone) else { return false }
        dictationNeedsPermission = status != .granted
        return status == .granted
    }

    /// Asks for the glasses' microphone permission, which opens Meta AI: what the phone's offer does, after it has said
    /// why. Returns whether it was granted.
    @discardableResult
    func allowDictation() async -> Bool {
        do {
            let granted = try await wearables.requestPermission(.microphone) == .granted
            dictationNeedsPermission = !granted
            return granted
        } catch {
            Self.logger.error("dictation permission: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// The names, read the first time a photo needs them.
    private func names() async -> NameableBirds? {
        guard let loadNames else { return nil }
        if namesTask == nil { namesTask = Task.detached(priority: .userInitiated) { await loadNames() } }
        return await namesTask?.value
    }

    /// The birds `words` may name for the photo of capture `capture`, the closest first, each with whether naming the
    /// photo as it would sew its patch. Ranked as "Name this bird" ranks a search: the birds this run has heard, in the
    /// lens's list order, then those likely where and when the photo was taken.
    private func birds(named words: String, forCapture capture: Int) async -> [LensNameMatch] {
        guard let unnamed = captured[capture], let names = await names() else { return [] }
        let machine = lens.machine
        let order = machine.order.indices.count == machine.stack.count ? machine.order.indices : Array(machine.stack.candidates.indices)
        let heard = order.map { machine.stack.candidates[$0].species.scientificName }
        let model = occurrenceModel, place = unnamed.location, takenAt = unnamed.takenAt
        // The geomodel is read for the photo's place and week, and ten thousand names are compared: off the main actor.
        let birds = await Task.detached(priority: .userInitiated) {
            names.spoken(words, in: NameableBirds.Context(heard: heard, place: place, takenAt: takenAt, occurrenceModel: model), limit: LensNaming.matchLimit)
        }.value
        offered[capture] = Dictionary(birds.map { ($0.scientificName, $0) }, uniquingKeysWith: { first, _ in first })
        return birds.map { bird in
            LensNameMatch(id: bird.scientificName, commonName: bird.commonName, isNewPatch: sightings.recorder.patchCount(ofSpeciesID: bird.speciesID, at: unnamed.location) == 0)
        }
    }

    /// Names the photo of capture `capture` as the bird the wearer tapped: the unnamed sighting becomes a sighting, Seen,
    /// through the run's ledger, exactly as naming it on the phone would, except that nothing is celebrated on a phone
    /// in a pocket: a patch it sews waits for its stitch-in as a lens add's does (`onPatchSewn`). Nil when it could not
    /// be written (the phone named or deleted the photo meanwhile, or the save failed): the photo is where it was.
    private func name(_ capture: Int, as match: LensNameMatch) -> LensNamedCapture? {
        guard let unnamed = captured[capture], let bird = offered[capture]?[match.id] else { return nil }
        do {
            let addition = try sightings.name(unnamed, as: bird)
            captured[capture] = nil
            offered[capture] = nil
            if addition.sewsPatch { onPatchSewn?(addition.identifier) }
            return LensNamedCapture(commonName: bird.commonName, place: addition.placement.setName, earned: addition.sewsPatch ? .newPatch : .seenAgain(count: addition.patchCount))
        } catch {
            Self.logger.error("naming from the lens failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The glasses are about to listen for a name. With the switch off the camera stream comes off the session first,
    /// as it does for a reference clip, and the run hears nothing until the dictation is over.
    private func dictationWillListen() async {
        guard !dictationKeepsStream(), let hold = source as? any DictationStreamHold else { return }
        dictationHold = hold
        await hold.holdForDictation()
    }

    private func dictationDidListen() {
        dictationHold?.releaseAfterDictation()
        dictationHold = nil
    }

    /// Writes a new sighting through the run's ledger, which the phone shares, and tells the lens what it earned: a new
    /// patch, or another sighting of one the birder has.
    func save(_ candidate: Candidate, confirmedAt: Date, frame: Data?) async {
        do {
            let addition = try sightings.add(candidate, confirmedAt: confirmedAt, location: listening.coordinate, frame: frame, source: .glasses)
            lens.earned(addition.sewsPatch ? .newPatch : .seenAgain(count: addition.patchCount), for: candidate.species)
            if addition.sewsPatch { onPatchSewn?(addition.identifier) }
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
