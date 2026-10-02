import Album
import Foundation
import Identification
import Observation
import OSLog
import SwiftData
import Synchronization

/// The latest audio level a source reported, written from the audio thread and read by the screen's waveform timer.
nonisolated final class LevelSink: Sendable {
    private let latest = Mutex(AudioLevel.silence)

    var level: AudioLevel {
        get { latest.withLock { $0 } }
        set { latest.withLock { $0 = newValue } }
    }
}

/// One listening run as the phone presents it (issue #28), over either audio source: the glasses run
/// (`GlassesListeningSession`) or the phone microphone (`ListeningSession`). The Listen tab, the listening accessory
/// on the other tabs and the candidate review all read this one object, so switching tabs never touches the run, and
/// the phone's "Add to journal" writes through the same ledger as the lens's "Add to my list".
@MainActor
@Observable
final class ListeningCoordinator {
    enum Source: String, CaseIterable, Identifiable {
        case glasses
        case phone

        var id: Self { self }

        var title: String {
            switch self {
            case .glasses: "Ray-Ban Display"
            case .phone: "iPhone microphone"
            }
        }

        var symbol: String {
            switch self {
            case .glasses: "eyeglasses"
            case .phone: "iphone"
            }
        }

        /// The line under the source row and beside the listening dot.
        var microphoneText: String {
            switch self {
            case .glasses: "Using glasses microphones"
            case .phone: "Using the iPhone microphone"
            }
        }
    }

    enum State: Equatable {
        case idle
        case starting
        case listening
        /// The glasses ended the session; the run is finding out whether the wearer quit or the glasses left.
        case interrupted
        case paused(GlassesListeningSession.PauseReason)
        case resuming
        case stopping
        /// The last run is over; its species stay for the review until the next start.
        case ended(EndReason)

        /// Whether a run is under way, including one waiting for the glasses.
        var isActive: Bool {
            switch self {
            case .starting, .listening, .interrupted, .paused, .resuming, .stopping: true
            case .idle, .ended: false
            }
        }
    }

    enum EndReason: Equatable {
        case stopped
        case endedByGlasses
        case failed(String)
    }

    /// The acknowledgment shown after an add, with its undo while the window is open.
    struct Acknowledgment: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let undo: RunSightings.Addition?
    }

    static let waveformLength = 40
    private static let logger = Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "listening")

    /// The source the next run uses; remembered across launches.
    var source: Source {
        didSet { defaults.set(source.rawValue, forKey: Self.sourceKey) }
    }
    /// The source of the run under way or the last one.
    private(set) var runSource: Source?
    /// The last `waveformLength` display levels, oldest first; refreshed a few times a second while listening.
    private(set) var waveform = [Float](repeating: 0, count: ListeningCoordinator.waveformLength)
    /// The Listen tab's list order (issue #42): calling now first, then most recently heard first. Refreshed with
    /// the waveform while the run is active, and settled with nothing calling once it ends.
    private(set) var listOrder = SpeciesListOrder()
    private(set) var acknowledgment: Acknowledgment?
    /// Set when a run that heard something ends, until the review is dismissed.
    var isReviewing = false
    /// The candidate the birder is reviewing, nil when none.
    var reviewing: Candidate?

    let phone: ListeningSession
    let glasses: GlassesListeningSession
    let sightings: RunSightings

    @ObservationIgnored private let levels: LevelSink
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var lastEnd: EndReason?
    @ObservationIgnored private var hasRun = false
    @ObservationIgnored private var waveformTask: Task<Void, Never>?
    @ObservationIgnored private var acknowledgmentTask: Task<Void, Never>?
    private static let sourceKey = "listeningSource"

    /// - Parameters:
    ///   - defaultSource: the source for a phone that has not chosen one: the glasses when a pair is linked.
    init(phone: ListeningSession, glasses: GlassesListeningSession, sightings: RunSightings, levels: LevelSink, defaultSource: Source, defaults: UserDefaults = .standard) {
        self.phone = phone
        self.glasses = glasses
        self.sightings = sightings
        self.levels = levels
        self.defaults = defaults
        source = defaults.string(forKey: Self.sourceKey).flatMap(Source.init(rawValue:)) ?? defaultSource
    }

    // MARK: - What the screens read

    /// The source of the run under way or the last one, else the one chosen for the next.
    var activeSource: Source { runSource ?? source }

    /// The listening session behind the run: the phone's, or the one inside the glasses run.
    private var listening: ListeningSession {
        activeSource == .glasses ? glasses.listening : phone
    }

    var state: State {
        guard let runSource else { return .idle }
        switch runSource {
        case .phone:
            switch phone.phase {
            case .starting: return .starting
            case .listening: return .listening
            case .stopping: return .stopping
            case .idle:
                guard hasRun else { return .idle }
                if let lastEnd { return .ended(lastEnd) }
                // The engine's stream ended on its own: a source or model failure.
                return .ended(phone.errorMessage.map(EndReason.failed) ?? .stopped)
            }
        case .glasses:
            switch glasses.phase {
            case .idle: return hasRun ? .ended(lastEnd ?? .stopped) : .idle
            case .starting: return .starting
            case .listening: return .listening
            case .interrupted: return .interrupted
            case .paused(let reason): return .paused(reason)
            case .resuming: return .resuming
            case .stopping: return .stopping
            case .stopped(.phone): return .ended(.stopped)
            case .stopped(.back), .stopped(.glasses): return .ended(.endedByGlasses)
            case .stopped(.failed(let message)): return .ended(.failed(message))
            }
        }
    }

    /// Every species heard this run, in the order they were admitted: the order the stack and the lens pages keep.
    var candidates: [Candidate] { listening.stack.candidates }
    /// The same species as the Listen tab lists them: calling now first (newest caller, then the one calling the
    /// longest), then the rest most recently heard first. Computed from the current stack over the remembered
    /// order, so a species that just arrived is placed at once.
    var orderedCandidates: [Candidate] {
        let candidates = candidates
        return currentOrder().indices.map { candidates[$0] }
    }
    /// Seconds since the run started listening, the clock the candidates' times are read against.
    var sessionTime: Double { listening.sessionTime }

    /// The species calling now, computed once per read; a screen asks this once per pass, not once per row.
    var callingSpecies: Set<Species> {
        let candidates = candidates
        return Set(currentOrder().calling.map { candidates[$0].species })
    }

    func isCalling(_ candidate: Candidate) -> Bool {
        callingSpecies.contains(candidate.species)
    }

    /// The remembered order brought up to the current stack and clock; nothing is calling once the run has ended.
    private func currentOrder() -> SpeciesListOrder {
        var order = listOrder
        order.update(with: listening.stack, at: state.isActive ? sessionTime : .infinity)
        return order
    }
    var startedAt: Date? { listening.startedAt }
    var locationState: ListeningSession.LocationState { listening.locationState }
    /// The location the next add records.
    var coordinate: Coordinate? { listening.coordinate }
    var errorMessage: String? { runSource == .glasses ? glasses.errorMessage : phone.errorMessage }
    var addedCount: Int { sightings.entries.count }

    func isAdded(_ candidate: Candidate) -> Bool { sightings.isAdded(candidate.species) }

    /// The summary line: "3 species heard · 1 added".
    var summary: String {
        "\(candidates.count) species heard · \(addedCount) added"
    }

    // MARK: - Lifecycle

    /// Starts a run over `source`. Ignored while one is active; a source switch needs a stop first.
    func start() async {
        Self.logger.info("start tapped: source \(self.source.rawValue, privacy: .public), state \(String(describing: self.state), privacy: .public)")
        guard !state.isActive else { return }
        lastEnd = nil
        isReviewing = false
        acknowledgment = nil
        hasRun = true
        runSource = source
        waveform = [Float](repeating: 0, count: Self.waveformLength)
        listOrder = SpeciesListOrder()
        levels.level = .silence
        switch source {
        case .phone:
            sightings.reset()
            await phone.start()
            if phone.phase != .listening { lastEnd = .failed(phone.errorMessage ?? "Listening did not start.") }
        case .glasses:
            await glasses.start()  // resets the shared ledger itself
        }
        Self.logger.info("start finished: state \(String(describing: self.state), privacy: .public)")
        if state == .listening { startWaveform() }
    }

    /// Ends the run; the species heard stay for the review.
    func stop() async {
        guard state.isActive else { return }
        stopWaveform()
        switch runSource {
        case .phone: await phone.stop()
        case .glasses: await glasses.stop()
        case nil: break
        }
        lastEnd = lastEnd ?? .stopped
        listOrder = currentOrder()
        isReviewing = !candidates.isEmpty
    }

    /// Clears the last run's species from the screen.
    func dismissEnded() {
        guard !state.isActive else { return }
        isReviewing = false
        runSource = nil
        hasRun = false
        lastEnd = nil
    }

    // MARK: - Adding

    /// Writes `candidate` to the journal with the location the run has and, on the glasses, the frame from this
    /// moment; acknowledges with an undo. A species already added this run has its sighting updated instead.
    @discardableResult
    func add(_ candidate: Candidate) async -> RunSightings.Addition? {
        let confirmedAt = Date.now
        let frame = runSource == .glasses ? await glasses.captureFrame() : nil
        do {
            let addition = try sightings.add(candidate, confirmedAt: confirmedAt, location: coordinate, frame: frame, source: runSource == .glasses ? .glasses : .phone)
            acknowledge(addition.wasNew ? "Added to your journal" : "Journal entry updated", undo: addition)
            return addition
        } catch {
            Self.logger.error("add failed: \(error.localizedDescription, privacy: .public)")
            acknowledge("Could not add the sighting: \(error.localizedDescription)", undo: nil)
            return nil
        }
    }

    func undo(_ addition: RunSightings.Addition) {
        do {
            try sightings.undo(addition)
            acknowledgment = nil
        } catch {
            Self.logger.error("undo failed: \(error.localizedDescription, privacy: .public)")
            acknowledge("Could not undo: \(error.localizedDescription)", undo: nil)
        }
    }

    private func acknowledge(_ text: String, undo: RunSightings.Addition?) {
        let acknowledgment = Acknowledgment(text: text, undo: undo)
        self.acknowledgment = acknowledgment
        acknowledgmentTask?.cancel()
        acknowledgmentTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, let self, self.acknowledgment == acknowledgment else { return }
            self.acknowledgment = nil
            self.sightings.commitReplacedFrames()  // the undo window has closed
        }
    }

    // MARK: - Waveform

    private func startWaveform() {
        waveformTask?.cancel()
        waveformTask = Task { [weak self, levels] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled, let self else { return }
                var next = self.waveform
                next.removeFirst()
                next.append(levels.level.displayValue)
                self.waveform = next
                // The list order follows the stack and the clock at the same pace; written only when it moves.
                let order = self.currentOrder()
                if order != self.listOrder { self.listOrder = order }
            }
        }
    }

    private func stopWaveform() {
        waveformTask?.cancel()
        waveformTask = nil
        waveform = [Float](repeating: 0, count: Self.waveformLength)
    }
}

extension GlassesListeningSession.PauseReason {
    /// What the phone says while the run waits, and the way out.
    var phoneText: String {
        switch self {
        case .glassesOff: "Glasses off. Put them on to carry on, or stop listening."
        case .disconnected: "Glasses out of range. Move closer to carry on, or stop listening."
        case .byGlasses: "Paused by the glasses. Tap the touchpad to carry on, or stop listening."
        }
    }

    var phoneTitle: String {
        switch self {
        case .glassesOff: "Paused: glasses off"
        case .disconnected: "Paused: glasses disconnected"
        case .byGlasses: "Paused by the glasses"
        }
    }
}
