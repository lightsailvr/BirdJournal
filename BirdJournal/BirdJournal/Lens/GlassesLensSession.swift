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
///
/// Stack updates carry the session time, which the adapter keeps as an origin on its own clock (issue #42): a
/// calling marker lapses with nothing in the stack changing, so the adapter schedules one re-send at the lapse
/// the list order reports, and re-evaluates the order before the pages go back on the lens after a suspension.
///
/// A tap on a sounds page plays the species' reference clips through `sounds` (issue #41, phase 4), the player the
/// phone's profile shares, so one clip plays at a time and listening never hears it. The card says where it plays
/// ("on the phone" when the glasses' A2DP speakers are not the route) and goes back when it ends. A swipe, a
/// problem page, a suspension (doff, lost link) and the end of the run stop it.
///
/// "Add to my list" opens the viewfinder: while it is the page, the camera's latest frame from `viewfinderFrame` is
/// re-sent as fast as the Display takes it (at most every `viewfinderInterval`). A tap there takes the photo and a
/// swipe adds the bird without one; both go to `onEffect` for the run to write. Hardware may deliver the Add press
/// twice, as a click and a select (DECISIONS.md, "Lens UI"), so a tap landing on the viewfinder within `echoWindow`
/// of its opening is that echo and is ignored rather than taking a photo of nothing in particular. The same holds for
/// every page a press opens whose own tap would undo that press (`LensPage.guardsItsTap`): "Say the bird's name" after
/// "Say it again", where the echo would be "Name it later", and "Photo saved" and "Added", which it would close unread.
///
/// "Capture a sighting", the row above the birds on the species list (issue #193), opens a viewfinder of its own for a
/// bird that was seen and not heard: the same frames, the same echo window, and a tap there asks `onCapture` for the
/// photo, which the run writes as an unnamed sighting for the phone to name. The lens waits on "Saving the photo…" until
/// the run answers with `captureSaved(_:)` ("Photo saved. Name it on your phone.") or `captureFailed(_:)` (a problem
/// page: nothing was saved). A swipe off that viewfinder saves nothing.
///
/// Where the run can hear a name (issue #194) it answers a saved photo with `captureSaved(_:askName:photo:)`, and the lens
/// goes on to "Say the bird's name". While that is the page, and only then, a `GlassesDictation` has the toolkit's Speech
/// on the session: its partial words go to the page, its final ones to `names` for the birds they may be, and the lens
/// lists them. A tap on a bird asks `names` to name the photo and shows what it earned. Leaving the page (a tap, a swipe,
/// a problem, a new session, a suspension, the end of the run) stops Speech, releases its listeners and takes it off the
/// session; a dictation that ends with nothing to match, and a lens suspended while listening, land on "Photo saved".
/// One dictation follows another in order, so "Say it again" never adds Speech before the last one is off.
///
/// Opening the viewfinder and landing back on the species list tell `onStreamNeeded`, so the run can put a camera
/// stream back that stopped or stalled (#46): the wearer is about to frame a bird, or is back to listening.
///
/// A friend's notable find (issue #67) reaches `friendFound(_:)` from the push center while the adapter holds a
/// run's pages (running, or suspended until the glasses come back); with no run it is dropped. The machine shows it
/// over the list or a photo page, or holds it; a held banner is dropped `LensStateMachine.bannerHoldLimit` after it
/// arrived, by a one-shot timer here and again before each gesture.
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
    /// Candidates added this run (from the viewfinder, with or without a photo), newest last; the listening run
    /// writes them to the album.
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
    /// Told about the viewfinder and saves; ending the session on Back is handled here.
    @ObservationIgnored private let onEffect: (LensEffect) -> Void
    /// How soon after an input opens a page that guards its tap (a viewfinder, "Say the bird's name" after "Say it
    /// again", "Photo saved", "Added") a tap there counts as that same press delivered twice.
    @ObservationIgnored private let echoWindow: Duration
    /// When an input last opened such a page.
    @ObservationIgnored private var pressOpenedPageAt: ContinuousClock.Instant?
    /// The camera's latest frame for the viewfinder; nil without a camera (a lens-only session), which the page says.
    @ObservationIgnored var viewfinderFrame: (() -> CameraFrame?)?
    /// Told when the viewfinder opens ("viewfinder") and when the wearer lands on the species list ("species list"),
    /// so the run can make sure the camera is streaming.
    @ObservationIgnored var onStreamNeeded: ((String) -> Void)?
    /// Told to take the capture viewfinder's photo and write it as an unnamed sighting (issue #193), and then to say how
    /// it went with `captureSaved(_:)` or `captureFailed(_:)` and the number it was given. Nil on a lens without a run,
    /// which has no camera: its captures fail at once.
    @ObservationIgnored var onCapture: ((Int) -> Void)?
    /// What saying a bird's name needs from the run behind the lens (issue #194); nil on a lens that never asks for one.
    @ObservationIgnored var names: LensNameSource?
    /// How long a dictation waits for words.
    @ObservationIgnored private let dictationLimits: GlassesDictation.Limits
    /// The dictation the lens is listening to, or about to: the machine's number for it, and the listener once it is on
    /// the session.
    @ObservationIgnored private var dictation: (id: Int, capture: Int, listener: GlassesDictation?)?
    /// Starts and stops of dictations, one after another.
    @ObservationIgnored private var dictationTask: Task<Void, Never>?
    /// The photo of the capture being named, sized for "Say the bird's name".
    @ObservationIgnored private var capturedPhoto: UIImage?
    /// The page the last change landed on, so arriving on the list is told once.
    @ObservationIgnored private var landedPage: LensPage = .list
    /// The least time between two viewfinder sends.
    @ObservationIgnored private let viewfinderInterval: Duration
    /// Re-sends the viewfinder page with each new frame while it is the page.
    @ObservationIgnored private var viewfinderTask: Task<Void, Never>?
    /// The frame the viewfinder page shows, sized for the lens.
    @ObservationIgnored private var viewfinderImage: UIImage?
    @ObservationIgnored private var lease: DeviceSessionLease = .own
    @ObservationIgnored private var session: DeviceSession?
    @ObservationIgnored private var display: Display?
    @ObservationIgnored private var inputsCapability: Inputs?
    @ObservationIgnored private var inputTask: Task<Void, Never>?
    /// The teardown in progress (a stop or a suspension), so a stop or resume that lands meanwhile awaits it.
    @ObservationIgnored private var teardownTask: Task<Void, Never>?
    /// Sends run one after another so a burst of gestures leaves the latest card on the lens.
    @ObservationIgnored private var sendTask: Task<Void, Never>?
    /// The instant session time zero fell on, from the latest stack update; nil before the first.
    @ObservationIgnored private var sessionOrigin: ContinuousClock.Instant?
    /// The one-shot re-send at the next calling marker's lapse.
    @ObservationIgnored private var lapseTask: Task<Void, Never>?
    @ObservationIgnored private let tokens = ListenerTokenBag()
    /// Plays the photo pages' reference clips; without it the pages offer none.
    @ObservationIgnored var sounds: (any LensSoundOutput)?
    /// The machine's playback the lens's clip belongs to, and the player's token for it, once it started.
    @ObservationIgnored private var soundClip: (playback: Int, clip: Int)?
    /// The playback waiting for the audio session, which has no token to stop it by yet.
    @ObservationIgnored private var startingSound: LensPlayback?
    /// Counts `start()`s: playback ids restart with each run's machine, so the player's late news of a clip from an
    /// earlier run is told apart by this.
    @ObservationIgnored private var runs = 0
    /// Zero on the clock the machine's friend banner times are on.
    @ObservationIgnored private let bannerClockOrigin = ContinuousClock.now
    /// The one-shot wake to drop a held friend banner.
    @ObservationIgnored private var bannerExpiryTask: Task<Void, Never>?
    /// Written straight from the toolkit callback, so the end of a run can tell a device-side end from a failure.
    @ObservationIgnored private nonisolated let lastSessionError = Mutex<DeviceSessionError?>(nil)

    init(
        wearables: any WearablesInterface = Wearables.shared,
        connection: GlassesConnection? = nil,
        profile: @escaping (Species) -> SpeciesProfile? = { _ in nil },
        image: @escaping (LensImage) -> UIImage? = { _ in nil },
        echoWindow: Duration = .seconds(1),
        viewfinderInterval: Duration = .milliseconds(150),
        dictationLimits: GlassesDictation.Limits = GlassesDictation.Limits(),
        onEffect: @escaping (LensEffect) -> Void = { _ in }
    ) {
        self.wearables = wearables
        self.connection = connection
        self.profile = profile
        self.image = image
        self.echoWindow = echoWindow
        self.viewfinderInterval = viewfinderInterval
        self.dictationLimits = dictationLimits
        self.onEffect = onEffect
        card = LensCardRenderer.render(LensStateMachine(), profile: profile)
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
        stopSound()
        runs += 1
        machine = LensStateMachine()
        landedPage = machine.page
        sessionOrigin = nil
        lapseTask?.cancel()
        lapseTask = nil
        bannerExpiryTask?.cancel()
        bannerExpiryTask = nil
        savedSightings = []
        pressOpenedPageAt = nil
        capturedPhoto = nil
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
        // A calling marker may have lapsed while the pages were off the lens.
        refreshOrder()
        await attachOrFail()
    }

    private func attachOrFail() async {
        lastSessionError.withLock { $0 = nil }
        do {
            try await attach()
            phase = .running
            // Back from a suspension onto the viewfinder (or a problem over it, cleared later).
            syncViewfinder()
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
        perform(machine.report(problem))
    }


    // MARK: - Stack

    /// The latest candidate stack from the engine (or the fake stack) at session time `time`, seconds since the
    /// run started listening: the pages follow it without moving, and the list order follows the clock.
    func update(with stack: CandidateStack, at time: Double) {
        sessionOrigin = .now - .seconds(time)
        if machine.update(with: stack, at: time) { refreshCard() }
        // A stack from a new session restarts the pages, and with them the clip and a dictation.
        if let soundClip, machine.playing?.id != soundClip.playback { stopSound() }
        syncDictation()
        scheduleLapse()
    }

    /// Seconds into the session on the adapter's own clock, from the latest update's origin.
    private var sessionTime: Double {
        guard let sessionOrigin else { return 0 }
        return Self.seconds(since: sessionOrigin)
    }

    /// Re-evaluates the list order at the current session time with the stack unchanged (a calling marker
    /// lapsed) and re-sends the card if it changed; then waits for the next lapse, if any.
    private func refreshOrder() {
        if sessionOrigin != nil, machine.update(with: machine.stack, at: sessionTime) { refreshCard() }
        scheduleLapse()
    }

    /// One re-send at the next lapse the list order reports (DECISIONS.md: whether a send wakes a dimmed display
    /// is checked on hardware; the fallback is to clear the marker on the next stack change only).
    private func scheduleLapse() {
        lapseTask?.cancel()
        lapseTask = nil
        guard sessionOrigin != nil, let lapse = machine.order.nextLapse else { return }
        let delay = max(lapse - sessionTime, 0)
        lapseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.refreshOrder()
        }
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
        lapseTask?.cancel()
        lapseTask = nil
        stopViewfinder()
        // Nobody is there to say a name: the photo is saved, and the pages come back saying so.
        if machine.page == .captureNaming, let naming = machine.naming, machine.dictationEnded(naming.dictation) { refreshCard() }
        syncDictation()
        // Speech comes off the session before Inputs, Display and the session itself go.
        await dictationTask?.value
        let display = self.display
        self.display = nil
        let inputs = inputsCapability
        inputsCapability = nil
        let session = self.session
        self.session = nil
        // The clip stops with the pages; they come back (after a doff or a lost link) without it.
        if let playing = machine.playing {
            machine.soundEnded(playing.id)
            refreshCard()
        }
        stopSound()
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
        if gesture == .tap, machine.page.guardsItsTap, let pressOpenedPageAt, ContinuousClock.now - pressOpenedPageAt < echoWindow {
            return
        }
        // A held banner past its limit must not show on the page this gesture lands on, even if the timer is late.
        machine.expireBanner(at: bannerTime)
        let before = machine.page
        perform(machine.apply(gesture) { [self] in cardProfile(for: $0)?.sounds ?? [] })
        notePress(from: before)
    }

    /// A tap on a card element (the Save button), delivered by Display rather than Inputs.
    private func tapped(_ action: LensAction) {
        guard phase == .running else { return }
        let before = machine.page
        perform(machine.press(action))
        notePress(from: before)
    }

    /// An input has been dealt with. If it opened a page whose own tap would undo it, the echo window starts: the same
    /// press arriving again within it, as a tap, is dropped (`LensPage.guardsItsTap`). A page the run opens by itself
    /// ("Say the bird's name" once the photo is saved) starts no window: no press is behind it.
    private func notePress(from before: LensPage) {
        if machine.page != before, machine.page.guardsItsTap { pressOpenedPageAt = .now }
    }

    /// The sighting an add of `species` wrote earned `patch` (issue #132): the details page's saved line names it.
    func earned(_ patch: LensEarnedPatch, for species: Species) {
        if machine.earned(patch, for: species) { refreshCard() }
    }

    private func perform(_ effect: LensEffect?) {
        switch effect {
        case .openViewfinder(let candidate):
            onEffect(.openViewfinder(candidate))
        case .openCaptureViewfinder:
            onEffect(.openCaptureViewfinder)
        case .capturePhoto(let id):
            if let onCapture {
                onCapture(id)
            } else {
                // No run behind the lens, so no camera: nothing was taken.
                _ = machine.captureFailed(id)
            }
        case .listenForName:
            // "Say the bird's name" is the page: `syncDictation()` below starts listening.
            break
        case .nameCapture(let capture, let match):
            // The write is the run's, and at once: the lens says what it earned, that the photo waits on the phone, or
            // that the phone got to it first.
            switch names?.name(capture, match) {
            case .named(let named): machine.captureNamed(capture, as: named)
            case .gone: machine.captureGone(capture)
            case .notWritten, nil: machine.captureNotNamed(capture)
            }
        case .takePhoto(let candidate):
            savedSightings.append(candidate)
            onEffect(.takePhoto(candidate))
        case .saveSighting(let candidate):
            savedSightings.append(candidate)
            onEffect(.saveSighting(candidate))
        case .endSession:
            beginStop(reason: .back)
            onEffect(.endSession)
        case .playSound(_, let playback):
            playSound(playback)
        case .stopSound:
            stopSound()
        case nil:
            break
        }
        if machine.naming == nil { capturedPhoto = nil }
        refreshCard()
        syncViewfinder()
        syncDictation()
        // A banner over the list is still the list for the camera: the wearer is back to listening.
        if machine.pageUnderBanner == .list, landedPage != .list { onStreamNeeded?("species list") }
        landedPage = machine.pageUnderBanner
        scheduleBannerExpiry()
    }

    // MARK: - Captures

    /// The photo of capture `id` is written, as an unnamed sighting on the phone (issue #193): the lens says so, if the
    /// wearer is still waiting for it. With `askName` (issue #194) the glasses can hear the bird's name, and the lens asks
    /// for it instead, showing `photo`, the picture just taken sized by `DisplayCardBuilder.capturedPhotoImage`.
    func captureSaved(_ id: Int, askName: Bool = false, photo: UIImage? = nil) {
        let asks = askName && names != nil && phase == .running
        if asks { capturedPhoto = photo }
        perform(machine.captureSaved(id, dictation: asks))
    }

    /// Capture `id` took no photo, or it could not be written: a problem page says nothing was saved.
    func captureFailed(_ id: Int) {
        perform(machine.captureFailed(id))
    }

    // MARK: - Saying the bird's name

    /// Listens for a name while "Say the bird's name" is the page of a running lens, and stops otherwise: Speech is on
    /// the session for that page only. Each change waits for the one before, so a dictation is off the session before
    /// the next is added.
    private func syncDictation() {
        let wanted = phase == .running && machine.page == .captureNaming ? machine.naming : nil
        guard dictation?.id != wanted?.dictation else { return }
        let previous = dictationTask
        let old = dictation?.listener
        dictation = wanted.map { ($0.dictation, $0.capture, nil) }
        dictationTask = Task { [weak self] in
            await previous?.value
            if let old {
                await old.stop()
                self?.names?.didListen()
            }
            guard let self, let wanted, self.dictation?.id == wanted.dictation, let session = self.session else { return }
            // The run may take the camera stream off first (`DictationSettings`).
            await self.names?.willListen()
            // Left meanwhile, or the session went: the stop that followed found no listener, so the stream is let go here.
            guard self.dictation?.id == wanted.dictation, self.session === session else {
                self.names?.didListen()
                return
            }
            let listener = GlassesDictation(session: session, limits: self.dictationLimits) { [weak self] event in
                self?.dictationDid(event, dictation: wanted.dictation, capture: wanted.capture)
            }
            self.dictation?.listener = listener
            listener.start()
        }
    }

    /// What a dictation heard. Words go to the page as they come; the final ones are matched by the run, and the lens
    /// lists the birds; an end with nothing to match is the saved page.
    private func dictationDid(_ event: GlassesDictation.Event, dictation id: Int, capture: Int) {
        switch event {
        case .words(let words):
            if machine.heard(words, dictation: id) { refreshCard() }
        case .final(let words):
            if machine.heard(words, dictation: id) { refreshCard() }
            guard let names, machine.page == .captureNaming, machine.naming?.dictation == id else { return }
            Task { [weak self] in
                let matches = await names.matches(words, capture)
                guard let self, self.machine.matched(words, matches, dictation: id) else { return }
                self.perform(nil)
            }
        case .ended:
            if machine.dictationEnded(id) { perform(nil) }
        }
    }

    // MARK: - Friend banners

    /// A friend's notable find arrived (issue #67): shown now over the list or a photo page, else held for the wearer's
    /// return. Dropped when no run holds the pages; while suspended it waits with them for the glasses.
    func friendFound(_ banner: LensFriendBanner) {
        guard isActive else { return }
        machine.friendFound(banner, at: bannerTime)
        refreshCard()
        scheduleBannerExpiry()
    }

    /// Seconds on the adapter's own steady clock, which the machine's banner times are on.
    private var bannerTime: Double { Self.seconds(since: bannerClockOrigin) }

    /// Seconds from `instant` to now, as the machine's clocks take them.
    private static func seconds(since instant: ContinuousClock.Instant) -> Double {
        let elapsed = (ContinuousClock.now - instant).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }

    /// One wake at the held banner's limit, to drop it; none when nothing is held.
    private func scheduleBannerExpiry() {
        bannerExpiryTask?.cancel()
        bannerExpiryTask = nil
        guard let expiry = machine.heldBannerExpiry else { return }
        // Just past the limit: "held for more than" five minutes.
        let delay = max(expiry - bannerTime, 0) + 0.05
        bannerExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.machine.expireBanner(at: self.bannerTime)
        }
    }

    // MARK: - Reference clips

    /// What the cards and the machine see of a species: the pack's profile, without clips when nothing can play them.
    private func cardProfile(for species: Species) -> SpeciesProfile? {
        guard var profile = profile(species) else { return nil }
        if sounds == nil { profile.sounds = [] }
        return profile
    }

    private func playSound(_ playback: LensPlayback) {
        stopSound()
        guard let sounds else {
            machine.soundEnded(playback.id)
            return
        }
        let run = runs
        startingSound = playback
        Task { [weak self] in
            let start = await sounds.play(playback.sound) { [weak self] in self?.soundDidEnd(playback.id, run: run) }
            guard let self else { return }
            if self.startingSound == playback { self.startingSound = nil }
            guard let start else {
                self.soundDidEnd(playback.id, run: run)
                return
            }
            // Stopped on the lens before it started (a stop the player could not cancel), or a later run's.
            guard self.runs == run, self.machine.playing?.id == playback.id else {
                sounds.stop(clip: start.clip)
                return
            }
            self.soundClip = (playback.id, start.clip)
            if !start.onGlasses, self.machine.soundPlaysOnPhone(playback.id) { self.refreshCard() }
        }
    }

    /// Stops the lens's clip, or cancels the one waiting for the audio session; a clip the phone started since is
    /// left alone.
    private func stopSound() {
        if let startingSound {
            self.startingSound = nil
            sounds?.cancelStart(of: startingSound.sound)
        }
        guard let soundClip else { return }
        self.soundClip = nil
        sounds?.stop(clip: soundClip.clip)
    }

    /// The clip ended on its own, failed to start, or was replaced by the phone's: the page goes back.
    private func soundDidEnd(_ playback: Int, run: Int) {
        guard run == runs else { return }
        if soundClip?.playback == playback { soundClip = nil }
        if machine.soundEnded(playback) { refreshCard() }
    }

    // MARK: - Viewfinder

    /// Starts the frame pump when the viewfinder is the page on a running lens, and stops it otherwise.
    private func syncViewfinder() {
        guard machine.page.isViewfinder, phase == .running, display != nil else {
            stopViewfinder()
            return
        }
        guard viewfinderTask == nil else { return }
        viewfinderTask = Task { [weak self] in await self?.pumpViewfinder() }
        onStreamNeeded?("viewfinder")
    }

    private func stopViewfinder() {
        viewfinderImage = nil
        guard let viewfinderTask else { return }
        viewfinderTask.cancel()
        self.viewfinderTask = nil
    }

    /// Sends the newest frame, waits for the Display to take it, and again: the Bluetooth link sets the pace, and
    /// `viewfinderInterval` keeps it from spending the link on frames no faster than the stream's own.
    private func pumpViewfinder() async {
        while !Task.isCancelled {
            let started = ContinuousClock.now
            if let frame = viewfinderFrame?() {
                if let image = await Task.detached(priority: .userInitiated, operation: { frame.image().map(DisplayCardBuilder.viewfinderImage) }).value,
                   !Task.isCancelled {
                    viewfinderImage = image
                    resendCard()
                    await sendTask?.value
                }
            } else if viewfinderImage != nil {
                // The camera is off or restarting: say so rather than leave the last picture standing.
                viewfinderImage = nil
                resendCard()
                await sendTask?.value
            }
            let rest = viewfinderInterval - (ContinuousClock.now - started)
            if rest > .zero { try? await Task.sleep(for: rest) }
        }
    }

    // MARK: - Display

    /// Re-renders the current page and sends it if it changed. Every page shows the stack (count, position, score),
    /// so a stack update on any page can change the card without changing the page.
    private func refreshCard() {
        let next = LensCardRenderer.render(machine, profile: cardProfile(for:))
        guard next != card else { return }
        card = next
        resendCard()
    }

    private func renderedCard() -> FlexBox {
        DisplayCardBuilder.flexBox(for: card, image: image, viewfinder: viewfinderImage, capturedPhoto: capturedPhoto) { [weak self] action in
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

/// What saying a bird's name on the lens needs from the run behind it (issue #194): the lens hears the words, the run
/// knows the birds and writes the sighting.
struct LensNameSource {
    /// The birds `words` may name for the photo of capture `capture`, the closest first.
    var matches: (_ words: String, _ capture: Int) async -> [LensNameMatch]
    /// Names the photo of capture `capture` as `match`, which writes its sighting, and says how that went: what it
    /// earned; that it could not be written, the photo then still unnamed on the phone; or that the phone had named or
    /// deleted the photo first.
    var name: (_ capture: Int, _ match: LensNameMatch) -> LensNamingOutcome
    /// The glasses are about to listen for a name: the moment to take the camera stream off, if the run does.
    var willListen: () async -> Void = {}
    /// They no longer are; called once for each `willListen`.
    var didListen: () -> Void = {}
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
