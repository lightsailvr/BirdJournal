import Foundation
import MWDATCore
import MWDATSpeech
import OSLog

/// The switch the field check flips (issue #194, DAT-SETUP-CHECKLIST.md step 16): whether the camera stream, which
/// carries the run's listening audio, stays on while the glasses listen for a bird's name. On, unless a debug build's
/// defaults say otherwise (`-dictationKeepsStream NO`, or the Developer screen's toggle). Nobody knows yet whether the
/// toolkit's Speech runs beside a stream that has the microphones; if it does not, off takes the stream off for the
/// seconds of a dictation, as a reference clip does.
///
/// A Release build never reads the switch: the Developer screen's toggle is written to the app's defaults, which a
/// Release build installed over a debug one inherits, and it has no screen to turn the stream back on with. Once the
/// field check has settled the answer, the default here is what ships.
enum DictationSettings {
    static let keepsStreamKey = "dictationKeepsStream"
    /// What every build does unless a debug build's switch says otherwise.
    static let keepsStreamByDefault = true

    static func keepsStream(_ defaults: UserDefaults = .standard) -> Bool {
        #if DEBUG
        defaults.object(forKey: keepsStreamKey) == nil ? keepsStreamByDefault : defaults.bool(forKey: keepsStreamKey)
        #else
        keepsStreamByDefault
        #endif
    }
}

/// The glasses run's camera stream, which a dictation of a bird's name holds while the glasses listen, when the field
/// check's switch says the toolkit's Speech does not run beside it (issue #194, `DictationSettings`). A hold of its own,
/// beside a reference clip's (`PlaybackStreamHold`) and a photo's.
@MainActor
protocol DictationStreamHold: AnyObject {
    /// Stops the stream for a dictation; returns once it is off.
    func holdForDictation() async
    /// The dictation is over; the stream may restart.
    func releaseAfterDictation()
}

/// What a dictation has heard so far, and what follows from each thing the toolkit's Speech reports (issue #194): every
/// decision of `GlassesDictation`, as a value, so it is tested without the glasses.
///
/// - **Final words**: a final transcription with words in it; an empty one is ignored. Words that are followed by nothing
///   for the pause are taken as final, and so are the words heard when Speech stops by itself (the toolkit stops it
///   after inactivity or a timeout): a wearer who said the name must not be told nothing was heard because the
///   recogniser never called it final.
/// - **Ended, with nothing to match**: nothing heard by the silence limit; Speech stopping by itself with nothing heard;
///   a `SpeechError`, whatever was heard before it; and Speech that cannot be added to the session.
///
/// After the final words or an end nothing more is told.
nonisolated struct DictationProgress: Equatable, Sendable {
    /// A wait the shell keeps for the progress, and reports back with `waited(_:)` when it runs out with nothing new.
    enum Wait: Equatable, Sendable {
        /// For a first word.
        case silence
        /// After words, for more or for the final ones.
        case pause
        /// After Speech stopped by itself, for an error that explains it.
        case stopGrace
    }

    /// What to do next: an event to tell, a wait to start in place of the one running, both or neither.
    struct Step: Equatable, Sendable {
        var event: GlassesDictation.Event?
        var wait: Wait?
    }

    /// The latest partial words.
    private(set) var words = ""
    /// Speech reached `.started` at least once: a `.stopped` from here on is Speech stopping, not its state before the start.
    private(set) var hasStarted = false
    /// The final words or an end have been told.
    private(set) var isOver = false

    /// A transcription, partial or final.
    mutating func heard(_ text: String, isFinal: Bool) -> Step {
        guard !isOver else { return Step() }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // No confidence check: the toolkit gives -1 when it has none, and a quiet "phoebe" is still a phoebe.
        guard !text.isEmpty else { return Step() }
        if isFinal { return finish(.final(text)) }
        words = text
        return Step(event: .words(text), wait: .pause)
    }

    /// Speech reported an error.
    mutating func failed(_ description: String) -> Step {
        finish(.ended(.failed(description)))
    }

    /// Speech could not be added to the session.
    mutating func unavailable(_ reason: String) -> Step {
        finish(.ended(.unavailable(reason)))
    }

    mutating func speechStarted() {
        hasStarted = true
    }

    /// Speech reported `.stopped`. Once it had started that is the toolkit stopping it (inactivity, a timeout, a
    /// constraint) without an error; an error that stopped it may be told a moment after the state, so the end waits.
    mutating func speechStopped() -> Step {
        guard hasStarted, !isOver else { return Step() }
        return Step(wait: .stopGrace)
    }

    /// The wait ran out with nothing new: the words so far are final, or there is nothing to match.
    mutating func waited(_ wait: Wait) -> Step {
        guard !isOver else { return Step() }
        if !words.isEmpty { return finish(.final(words)) }
        return finish(.ended(wait == .stopGrace ? .stopped : .silence))
    }

    private mutating func finish(_ event: GlassesDictation.Event) -> Step {
        guard !isOver else { return Step() }
        isOver = true
        return Step(event: event)
    }
}

/// One dictation on the glasses (issue #194): the toolkit's Speech capability added to the run's device session, started,
/// listened to, and stopped and removed again. The lens adapter makes one each time "Say the bird's name" becomes the
/// page and stops it when the page is left, so Speech is on the session only while the lens is listening for a name.
///
/// What it tells its owner, on the main actor: the words so far (a partial transcription), the final words, or that it
/// ended with nothing to match (`DictationProgress` decides which). After the final words or an end it says nothing more
/// and has stopped recognising; `stop()` then takes Speech off the session.
final class GlassesDictation {
    nonisolated enum Event: Equatable, Sendable {
        /// The words heard so far; more may come.
        case words(String)
        /// The words to match: the dictation is over.
        case final(String)
        /// The dictation is over with nothing to match.
        case ended(End)
    }

    nonisolated enum End: Equatable, Sendable {
        /// Nothing was heard in time.
        case silence
        /// Speech stopped by itself before anything was heard.
        case stopped
        /// Speech reported an error.
        case failed(String)
        /// Speech could not be added to the session.
        case unavailable(String)
    }

    nonisolated struct Limits: Sendable {
        /// How long the glasses listen for a first word.
        var silence: Duration = .seconds(8)
        /// How long after the last words, with no final ones, before they are taken as final.
        var pause: Duration = .seconds(3)
        /// How long Speech's own stop waits for an error that explains it.
        var stopGrace: Duration = .milliseconds(250)

        init() {}

        init(silence: Duration, pause: Duration) {
            self.silence = silence
            self.pause = pause
        }

        /// The app's limits. In a debug build `-dictationSilenceSeconds <s>` sets how long the glasses listen for a first
        /// word and `-dictationPauseSeconds <s>` how long words wait for more, to hold "Say the bird's name" for a
        /// screenshot or cut a test's wait.
        static var forApp: Limits {
            var limits = Limits()
            #if DEBUG
            let silence = UserDefaults.standard.double(forKey: "dictationSilenceSeconds")
            if silence > 0 { limits.silence = .seconds(silence) }
            let pause = UserDefaults.standard.double(forKey: "dictationPauseSeconds")
            if pause > 0 { limits.pause = .seconds(pause) }
            #endif
            return limits
        }

        func duration(of wait: DictationProgress.Wait) -> Duration {
            switch wait {
            case .silence: silence
            case .pause: pause
            case .stopGrace: stopGrace
            }
        }
    }

    private static let logger = Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "dictation")

    private let session: DeviceSession
    private let limits: Limits
    private let onEvent: (Event) -> Void
    private var speech: Speech?
    private let tokens = ListenerTokenBag()
    private var progress = DictationProgress()
    /// Stopped by its owner: nothing more is told.
    private var isStopped = false
    /// The wait running for the progress.
    private var waitTask: Task<Void, Never>?

    init(session: DeviceSession, limits: Limits = Limits(), onEvent: @escaping (Event) -> Void) {
        self.session = session
        self.limits = limits
        self.onEvent = onEvent
    }

    /// Adds Speech to the session and starts it. The listeners are in place before the start, so nothing is missed.
    func start() {
        guard speech == nil, !isStopped, !progress.isOver else { return }
        do {
            guard let speech = try session.addSpeech() else {
                take(progress.unavailable("the session is not started"))
                return
            }
            self.speech = speech
            speech.transcriptionPublisher.listen { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    self.take(self.progress.heard(result.text, isFinal: result.isFinal))
                }
            }.store(in: tokens)
            speech.errorPublisher.listen { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    self.take(self.progress.failed(error.description))
                }
            }.store(in: tokens)
            speech.statePublisher.listen { [weak self] state in
                Task { @MainActor in self?.stateChanged(to: state) }
            }.store(in: tokens)
            speech.start()
            GlassesLog.shared.note("dictation: listening")
            take(DictationProgress.Step(wait: .silence))
        } catch {
            take(progress.unavailable(error.description))
        }
    }

    /// Stops Speech, releases its listeners and takes it off the session, in that order (the toolkit wants the tokens
    /// cancelled before the removal). Safe to call at any time, and more than once.
    func stop() async {
        isStopped = true
        waitTask?.cancel()
        waitTask = nil
        guard let speech else { return }
        self.speech = nil
        speech.stop()
        await tokens.cancelAll()
        do {
            try session.removeSpeech()
        } catch {
            // A session the glasses ended has taken Speech with it.
            Self.logger.info("Speech not removed: \(error.description, privacy: .public)")
        }
    }

    private func stateChanged(to state: SpeechState) {
        guard !isStopped, !progress.isOver else { return }
        // For the field check: what Speech itself reported, beside what the lens made of it.
        GlassesLog.shared.note("dictation: Speech \(state)")
        switch state {
        case .started: progress.speechStarted()
        case .stopped: take(progress.speechStopped())
        case .starting, .stopping: break
        @unknown default: break
        }
    }

    /// Does what the progress asks: starts the wait in place of the one running, and tells the event.
    private func take(_ step: DictationProgress.Step) {
        guard !isStopped else { return }
        if let wait = step.wait {
            waitTask?.cancel()
            waitTask = Task { [weak self, limits] in
                try? await Task.sleep(for: limits.duration(of: wait))
                guard !Task.isCancelled, let self else { return }
                self.take(self.progress.waited(wait))
            }
        }
        guard let event = step.event else { return }
        if progress.isOver {
            waitTask?.cancel()
            waitTask = nil
            // Recognition is over; Speech stays on the session until `stop()`.
            speech?.stop()
            GlassesLog.shared.note("dictation: \(Self.logText(event))")
        }
        onEvent(event)
    }

    /// The event for the glasses log, which is a file: what was said is in it only in a debug build, for the field check.
    private static func logText(_ event: Event) -> String {
        switch event {
        case .words(let words), .final(let words):
            #if DEBUG
            return "heard \"\(words)\""
            #else
            return "heard \(words.split(whereSeparator: \.isWhitespace).count) words"
            #endif
        case .ended(.silence): return "nothing heard in time"
        case .ended(.stopped): return "Speech stopped with nothing heard"
        case .ended(.failed(let error)): return "Speech error: \(error)"
        case .ended(.unavailable(let reason)): return "Speech unavailable: \(reason)"
        }
    }
}
