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
/// the phone's "Add to collection" writes through the same ledger as the lens's "Add to my list".
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
        /// What it says first, for a moment, before it ticks over to `text` with a haptic: a repeat add's count going 7 → 8.
        var ticksFrom: String? = nil
        let undo: RunSightings.Addition?
    }

    /// What the phone shows over everything after an add that sewed a patch (issues #132, #135; before them the Legendary
    /// reveal of #51): the stitch-in and the new patch, the species' first surviving sighting in its placement. An event of
    /// the add, not of the patch: it shows once, and reopening the patch never shows it again.
    struct Reveal: Identifiable, Equatable {
        let addition: RunSightings.Addition
        let commonName: String
        /// Its one moment is over: the stitch-in finished or was tapped through. Kept here, not in the view: when a run ends
        /// under it the page moves from over the tabs to over the review, and that shouldn't play it a second time.
        var hasPlayed = false
        /// A patch the lens sewed, its ceremony held until the run was over: minutes or days after the add, so no Undo.
        var isFromGlasses = false

        var id: UUID { addition.identifier }
        /// "Your first House Finch in Los Angeles"; outside every set, "Your first House Finch".
        var title: String {
            addition.placement.setID == nil ? "Your first \(commonName)" : "Your first \(commonName) in \(addition.placement.setName)"
        }
        /// "New patch, Citrus edition".
        var eyebrow: String { "New patch, \(addition.placement.editionLabel)" }
    }

    /// What a repeat add says: "House Finch seen again, 8 times in Los Angeles", or "House Finch seen again, 8 times" outside
    /// every set. It names the bird because nothing else does: a repeat has no reveal, and a live list can move another bird's
    /// Add under a thumb (issue #150). In digits even for 1, unlike `Patch.times`'s "once": it's what the count ticks up from.
    private static func seenAgainText(_ name: String, _ placement: CardPlacement, count: Int) -> String {
        let times = "\(count) \(count == 1 ? "time" : "times")"
        return placement.setID == nil ? "\(name) seen again, \(times)" : "\(name) seen again, \(times) in \(placement.setName)"
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
    /// The page showing after an add that sewed a patch, until the birder dismisses it or undoes the add.
    private(set) var reveal: Reveal?
    /// The sightings whose patches the lens sewed, in the order sewn, each until its ceremony has played: the glasses are
    /// for hearing and capturing, and the celebration is on the phone once the run is over (the maintainer, 2026-11-04). The
    /// run often ends with the phone in a pocket and the app can be killed before it's next in front, so this outlives the
    /// app, in the defaults: identifiers only, since the album has the rest and a sighting deleted meanwhile is skipped.
    private(set) var pendingCeremonies: [UUID] {
        didSet { defaults.set(pendingCeremonies.map(\.uuidString), forKey: Self.pendingCeremoniesKey) }
    }
    /// When the run ended, by Stop or on its own: what the recap counts the time to, however long the review waits to be seen.
    private(set) var endedAt: Date?
    /// The time the run has spent paused, so "listened" doesn't count it.
    private(set) var clock = ListeningClock()
    /// A run that had ended and was waiting for its review when the app was killed: the birds heard, read back at launch.
    private(set) var restored: EndedRun?
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
    /// From Stop until the run's end has been dealt with, so a ceremony starts over the review rather than just before it.
    private var isEnding = false
    @ObservationIgnored private let archive: UserDefaults?
    static let sourceKey = "listeningSource"
    static let endedRunKey = "endedRunAwaitingReview"
    private static let pendingCeremoniesKey = "pendingPatchCeremonies"

    /// - Parameters:
    ///   - defaultSource: the source for a phone that has not chosen one: the glasses when a pair is linked.
    ///   - archive: where a review waiting to be seen outlives the app; by default `defaults`, and with nil it doesn't.
    init(phone: ListeningSession, glasses: GlassesListeningSession, sightings: RunSightings, levels: LevelSink, defaultSource: Source, defaults: UserDefaults = .standard, archive: UserDefaults?? = .none) {
        self.phone = phone
        self.glasses = glasses
        self.sightings = sightings
        self.levels = levels
        self.defaults = defaults
        source = defaults.string(forKey: Self.sourceKey).flatMap(Source.init(rawValue:)) ?? defaultSource
        pendingCeremonies = defaults.stringArray(forKey: Self.pendingCeremoniesKey)?.compactMap(UUID.init(uuidString:)) ?? []
        self.archive = archive ?? defaults
        glasses.onPatchSewn = { [weak self] identifier in self?.pendingCeremonies.append(identifier) }
        restoreEndedRun()
        followState()
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

    private var stack: CandidateStack {
        #if DEBUG
        if let fakeStack { return fakeStack }
        #endif
        if let restored { return CandidateStack(candidates: restored.candidates) }
        return listening.stack
    }

    #if DEBUG
    /// `-fakeRunBirds` (issue #150): the birds a run has heard, standing still, for the UI tests and the screenshots.
    var fakeStack: CandidateStack?
    #endif

    /// Every species heard this run, in the order they were admitted: the order the stack and the lens pages keep.
    var candidates: [Candidate] { stack.candidates }
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
        order.update(with: stack, at: state.isActive ? sessionTime : .infinity)
        return order
    }
    var startedAt: Date? { restored?.startedAt ?? listening.startedAt }
    /// Where a clock counting only the time listened starts: the start, moved on by the time paused.
    var clockStart: Date? { startedAt.map(clock.shownStart(from:)) }
    /// Where that clock stands still: while the run is paused, and once it has ended.
    var clockStoppedAt: Date? { clock.pausedSince ?? endedAt }
    /// The time the run spent listening, up to its end or now.
    var listened: TimeInterval { clock.listened(from: startedAt, to: endedAt ?? .now) }
    var locationState: ListeningSession.LocationState { listening.locationState }
    /// The location the next add records.
    var coordinate: Coordinate? { restored?.coordinate ?? listening.coordinate }
    /// When that location was fixed.
    var locationFixedAt: Date? { listening.locationFixedAt }
    /// Whether a phone-microphone run holds the audio session, which a reference clip then plays in (issue #41).
    var phoneRunHoldsSession: Bool { runSource == .phone && state.isActive }
    var errorMessage: String? { runSource == .glasses ? glasses.errorMessage : phone.errorMessage }

    func isAdded(_ candidate: Candidate) -> Bool { sightings.isAdded(candidate.species) }

    /// The summary line's counts, against the patches an add here would join: "1 new patch waiting and 2 you already have".
    func hunt(in collection: CardCollection) -> RunHunt {
        RunHunt(candidates: candidates, collection: collection, at: coordinate)
    }

    // MARK: - Lifecycle

    /// Starts a run over `source`. Ignored while one is active; a source switch needs a stop first.
    func start() async {
        Self.logger.info("start tapped: source \(self.source.rawValue, privacy: .public), state \(String(describing: self.state), privacy: .public)")
        guard !state.isActive else { return }
        lastEnd = nil
        endedAt = nil
        clock = ListeningClock()
        forgetEndedRun()
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
        isEnding = true
        defer { isEnding = false }
        stopWaveform()
        switch runSource {
        case .phone: await phone.stop()
        case .glasses: await glasses.stop()
        case nil: break
        }
        lastEnd = lastEnd ?? .stopped
        settleEnd()
    }

    /// What every end of a run comes to, by Stop or on its own (Back on the lens, the source giving out): the clock stops, and
    /// what was heard goes to the review. Once per run.
    private func settleEnd() {
        guard endedAt == nil else { return }
        endedAt = .now
        stopWaveform()
        listOrder = currentOrder()
        isReviewing = !candidates.isEmpty
        // The page moves to over the review: it picks up as finished rather than starting again.
        if isReviewing { finishCeremony() }
        keepEndedRun()
    }

    /// Every change of state from launch on, wherever it came from and whatever's on screen: the paused time, and a run that
    /// ended without Stop.
    private func followState() {
        let state = withObservationTracking { self.state } onChange: { [weak self] in
            Task { @MainActor in self?.followState() }
        }
        switch state {
        case .interrupted, .paused, .resuming: clock.note(isPaused: true, at: .now)
        default: clock.note(isPaused: false, at: .now)
        }
        // Stop settles the end itself, with its reason.
        if case .ended = state, !isEnding { settleEnd() }
    }

    /// Clears the last run's species from the screen.
    func dismissEnded() {
        guard !state.isActive else { return }
        forgetEndedRun()
        isReviewing = false
        runSource = nil
        hasRun = false
        lastEnd = nil
    }

    // MARK: - Adding

    /// Writes `candidate` to the journal with the location the run has and, on the glasses, the frame from this
    /// moment; acknowledges with an undo. Every add is a new sighting, even of a species already added this run; the
    /// first in a placement sews the species' patch there and opens its ceremony, and the rest tick its count in the
    /// acknowledgment, with nothing to tap (the maintainer, 2026-11-04). Either way the sighting is saved before anything shows.
    @discardableResult
    func add(_ candidate: Candidate, method: SightingMethod = .heard) async -> RunSightings.Addition? {
        // From a recap, even one days old, the bird was met on that run, not today: the patch and the find both say when.
        let confirmedAt = endedAt ?? .now
        let frame = runSource == .glasses ? await glasses.captureFrame() : nil
        do {
            let addition = try sightings.add(candidate, confirmedAt: confirmedAt, location: coordinate, frame: frame, source: runSource == .glasses ? .glasses : .phone, method: method)
            keepEndedRun()
            if addition.sewsPatch {
                let reveal = Reveal(addition: addition, commonName: candidate.species.commonName)
                self.reveal = reveal
                acknowledge(reveal.title, undo: addition)
            } else {
                acknowledge(
                    Self.seenAgainText(candidate.species.commonName, addition.placement, count: addition.patchCount),
                    ticksFrom: Self.seenAgainText(candidate.species.commonName, addition.placement, count: addition.patchCount - 1),
                    undo: addition
                )
            }
            return addition
        } catch {
            Self.logger.error("add failed: \(error.localizedDescription, privacy: .public)")
            acknowledge("Could not add the sighting: \(error.localizedDescription)", undo: nil)
            return nil
        }
    }

    /// The Sew it or Add on a bird's row (issue #150, L2): the review sheet's own add, with its reveal, count and Undo, as Heard,
    /// which the sighting's page can change. A bird no installed pack describes goes to its review and nothing is written: it
    /// isn't added with nothing to compare it against.
    @discardableResult
    func addFromRow(_ candidate: Candidate, isDescribed: Bool) async -> RunSightings.Addition? {
        guard isDescribed else {
            reviewing = candidate
            return nil
        }
        return await add(candidate, method: .heard)
    }

    #if DEBUG
    /// The reveal for a seeded sighting, for `-autoScreen reveal`; there is no add to undo.
    func showRevealForScreenshot(of sighting: Sighting, placement: CardPlacement = .uncharted) {
        let species = Species(index: 0, scientificName: sighting.scientificName, commonName: sighting.commonName, taxonomicClass: "Aves")
        reveal = Reveal(addition: RunSightings.Addition(species: species, sightingID: sighting.persistentModelID, identifier: sighting.identifier, sewsPatch: true, patchCount: 1, placement: placement), commonName: sighting.commonName)
    }
    #endif

    /// The page's moment is over: from here it shows the finished patch. Undo's window starts again, since the page only
    /// offers Undo from here, and the stitch-in would otherwise have used most of it up.
    func finishCeremony() {
        guard let reveal, !reveal.hasPlayed else { return }
        self.reveal?.hasPlayed = true
        if reveal.isFromGlasses {
            // Only now: killed part way through the stitch-in, it hasn't played.
            pendingCeremonies.removeAll { $0 == reveal.addition.identifier }
        } else if sightings.entries.contains(where: { $0.id == reveal.addition.sightingID }) {
            acknowledge(reveal.title, undo: reveal.addition)
        }
    }

    /// Closes the reveal, and shows the next waiting ceremony if there is one; the sighting was saved before it opened.
    func dismissReveal() {
        reveal = nil
        showNextCeremony()
    }

    // MARK: - A review that outlives the app

    /// Writes the ended run down while its review waits. Stop on the Lock Screen leaves the app suspended, holding a model in
    /// memory, and iOS may well kill it before the birder is back: their birds shouldn't go with it.
    private func keepEndedRun() {
        guard isReviewing, let archive, let startedAt, let endedAt, let runSource else { return }
        let run = EndedRun(
            source: runSource.rawValue, startedAt: startedAt, endedAt: endedAt, listened: clock.listened(from: startedAt, to: endedAt),
            coordinate: coordinate, birds: candidates.map(EndedRun.Bird.init), added: sightings.entries.map { .init(identifier: $0.identifier, bird: .init($0.candidate)) }
        )
        archive.set(try? JSONEncoder().encode(run), forKey: Self.endedRunKey)
    }

    private func forgetEndedRun() {
        restored = nil
        archive?.removeObject(forKey: Self.endedRunKey)
    }

    /// At launch: the review a killed app was waiting to show, with what it had added.
    private func restoreEndedRun() {
        guard let data = archive?.data(forKey: Self.endedRunKey), let run = try? JSONDecoder().decode(EndedRun.self, from: data), !run.birds.isEmpty else { return }
        restored = run
        runSource = Source(rawValue: run.source)
        hasRun = true
        lastEnd = .stopped
        endedAt = run.endedAt
        clock = ListeningClock(alreadyPaused: run.endedAt.timeIntervalSince(run.startedAt) - run.listened)
        sightings.restore(run.added.map { ($0.identifier, $0.bird.candidate) })
        listOrder = currentOrder()
        isReviewing = true
    }

    // MARK: - Ceremonies after a glasses run

    /// A ceremony is waiting and could start: the run is over and nothing is showing, or about to, that it would play under.
    /// The screen brings the other half, whether the app is in front.
    var hasCeremonyWaiting: Bool {
        !pendingCeremonies.isEmpty && reveal == nil && reviewing == nil && !isEnding && !state.isActive
    }

    /// How many more ceremonies follow the finished page showing; none while a run is on, when they aren't offered yet.
    var waitingCeremonies: Int {
        state.isActive ? 0 : pendingCeremonies.count
    }

    /// Shows the first waiting ceremony whose sighting is still in the album, and forgets those that aren't.
    func showNextCeremony() {
        while hasCeremonyWaiting, let identifier = pendingCeremonies.first {
            if let addition = sightings.sewnAddition(of: identifier) {
                reveal = Reveal(addition: addition, commonName: addition.species.commonName, isFromGlasses: true)
            } else {
                pendingCeremonies.removeFirst()
            }
        }
    }

    /// Closes the page and lets every waiting ceremony go. The patches are sewn all the same.
    func skipCeremonies() {
        pendingCeremonies = []
        reveal = nil
    }

    func undo(_ addition: RunSightings.Addition) {
        do {
            try sightings.undo(addition)
            keepEndedRun()
            acknowledgment = nil
            if reveal?.addition == addition { reveal = nil }
        } catch {
            Self.logger.error("undo failed: \(error.localizedDescription, privacy: .public)")
            acknowledge("Could not undo: \(error.localizedDescription)", undo: nil)
        }
    }

    private func acknowledge(_ text: String, ticksFrom: String? = nil, undo: RunSightings.Addition?) {
        let acknowledgment = Acknowledgment(text: text, ticksFrom: ticksFrom, undo: undo)
        self.acknowledgment = acknowledgment
        acknowledgmentTask?.cancel()
        acknowledgmentTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, let self, self.acknowledgment == acknowledgment else { return }
            self.acknowledgment = nil
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

/// The time a run has spent paused, so a clock can count only the time it spent listening (issue #150). Glasses off or out of
/// range isn't listening. A pure value, fed each change of the run's state.
struct ListeningClock: Equatable {
    private var pausedTotal: TimeInterval
    /// Since when it's been paused; nil while it isn't.
    private(set) var pausedSince: Date?

    init(alreadyPaused: TimeInterval = 0) {
        pausedTotal = max(alreadyPaused, 0)
    }

    mutating func note(isPaused: Bool, at date: Date) {
        if isPaused {
            pausedSince = pausedSince ?? date
        } else if let since = pausedSince {
            pausedTotal += max(date.timeIntervalSince(since), 0)
            pausedSince = nil
        }
    }

    /// The time listened from `start` up to `end`, or up to the pause `end` fell in.
    func listened(from start: Date?, to end: Date) -> TimeInterval {
        guard let start else { return 0 }
        return max(min(end, pausedSince ?? end).timeIntervalSince(start) - pausedTotal, 0)
    }

    /// Where to start a clock that reads the time listened, for now.
    func shownStart(from start: Date) -> Date {
        start.addingTimeInterval(pausedTotal)
    }
}

/// A run that has ended, as far as its review needs it, written down until the review has been seen.
nonisolated struct EndedRun: Codable, Equatable, Sendable {
    struct Bird: Codable, Equatable, Sendable {
        let index: Int
        let scientificName: String
        let commonName: String
        let taxonomicClass: String
        let score: Float
        let windowsAboveThreshold: Int
        let firstHeardAt: Double
        let lastHeardAt: Double
        let admittedAt: Double

        init(_ candidate: Candidate) {
            index = candidate.species.index
            scientificName = candidate.species.scientificName
            commonName = candidate.species.commonName
            taxonomicClass = candidate.species.taxonomicClass
            score = candidate.score
            windowsAboveThreshold = candidate.windowsAboveThreshold
            firstHeardAt = candidate.firstHeardAt
            lastHeardAt = candidate.lastHeardAt
            admittedAt = candidate.admittedAt
        }

        var candidate: Candidate {
            Candidate(
                species: Species(index: index, scientificName: scientificName, commonName: commonName, taxonomicClass: taxonomicClass),
                score: score, windowsAboveThreshold: windowsAboveThreshold, firstHeardAt: firstHeardAt, lastHeardAt: lastHeardAt, admittedAt: admittedAt
            )
        }
    }

    struct Added: Codable, Equatable, Sendable {
        let identifier: UUID
        let bird: Bird
    }

    let source: String
    let startedAt: Date
    let endedAt: Date
    let listened: TimeInterval
    let coordinate: Coordinate?
    let birds: [Bird]
    let added: [Added]

    var candidates: [Candidate] { birds.map(\.candidate) }
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
