import Album
import CoreLocation
import Foundation
import Identification
import Observation
import OSLog

/// One listening run over an `AudioSource`: the phone microphone with no glasses (issue #6) or the glasses stream
/// (issue #9). The source feeds the engine, the location stream is read for the whole run so every add records
/// where it was made (issue #44), and the live list on the screen follows the stack; `onStack` hands each new stack
/// to whoever else follows it (the lens). Stop ends the run. Reusable: `start()` after `stop()` begins a fresh
/// session.
@Observable
final class ListeningSession {
    enum Phase: Equatable {
        case idle
        case starting
        case listening
        case stopping
    }

    enum LocationState: Equatable {
        case unknown
        case requesting
        /// What the stream last delivered. `.denied` and `.unavailable` mean identification runs without the
        /// regional filter; `.unavailable` after a fix keeps the earlier fix instead.
        case settled(LocationFix)
    }

    /// How far the birder moves before the engine's geo filter follows: the species prior is not recomputed on
    /// every step, and a few kilometres change nothing in it.
    static let geoFilterMoveThreshold: CLLocationDistance = 5_000
    private static let logger = Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "listening")

    private(set) var phase: Phase = .idle
    private(set) var locationState: LocationState = .unknown
    private(set) var list = LiveCandidateList()
    private(set) var stack = CandidateStack()
    private(set) var windowsScored = 0
    private(set) var lastWindow: WindowReport?
    private(set) var startedAt: Date?
    var errorMessage: String?

    @ObservationIgnored private let loadEngine: @Sendable () async throws -> IdentificationEngine
    @ObservationIgnored private let makeSource: () -> any AudioSource
    @ObservationIgnored private let location: any LocationProvider
    @ObservationIgnored private let onStack: (CandidateStack) -> Void
    @ObservationIgnored private var source: (any AudioSource)?
    @ObservationIgnored private var context: LiveGeoContext?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var locationTask: Task<Void, Never>?

    init(
        loadEngine: @escaping @Sendable () async throws -> IdentificationEngine = { try await BundledIdentification.engine() },
        makeSource: @escaping () -> any AudioSource = { PhoneMicAudioSource() },
        location: any LocationProvider = CoreLocationProvider(),
        onStack: @escaping (CandidateStack) -> Void = { _ in }
    ) {
        self.loadEngine = loadEngine
        self.makeSource = makeSource
        self.location = location
        self.onStack = onStack
    }

    /// Seconds since the run started listening: the clock `Candidate` times are read against (the engine's window
    /// times run from the first chunk, a beat after). Zero before the run starts.
    var sessionTime: Double {
        startedAt.map { Date.now.timeIntervalSince($0) } ?? 0
    }

    /// The latest location fix as the album records it, nil while identification runs without one.
    var coordinate: Coordinate? {
        guard case .settled(.fix(let latitude, let longitude, let accuracy, _)) = locationState else { return nil }
        return Coordinate(latitude: latitude, longitude: longitude, accuracy: accuracy)
    }

    /// When the latest fix was taken, for the place line's "updated N min ago".
    var locationFixedAt: Date? {
        guard case .settled(.fix(_, _, _, let at)) = locationState else { return nil }
        return at
    }

    /// Starts over the source `makeSource` gives.
    func start() async {
        guard phase == .idle else { return }
        await start(source: makeSource())
    }

    /// Loads the models and waits for the first location fix side by side, then starts `source` and keeps reading
    /// the location stream. On failure the session is idle again with `errorMessage` set.
    func start(source: any AudioSource) async {
        guard phase == .idle else { return }
        phase = .starting
        errorMessage = nil
        list = LiveCandidateList()
        stack = CandidateStack()
        windowsScored = 0
        lastWindow = nil
        startedAt = nil
        locationState = .requesting

        async let loading = loadEngine()
        let fixes = FixReader(location.fixes())
        let context = LiveGeoContext(record(await fixes.next() ?? .unavailable))
        self.context = context
        do {
            let engine = try await loading
            self.source = source
            let events = try await engine.identify(source, in: context)
            startedAt = .now
            phase = .listening
            eventTask = Task { [weak self] in
                do {
                    for try await event in events { self?.handle(event) }
                } catch {
                    self?.errorMessage = error.localizedDescription
                    Self.logger.error("identification ended: \(error.localizedDescription, privacy: .public)")
                }
                self?.sessionEnded()
            }
            locationTask = Task { [weak self, fixes] in
                // The rest of the stream, which buffered whatever arrived while the engine loaded.
                while let fix = await fixes.next() {
                    // Stop may have landed while waiting; a stale fix must not touch the next session.
                    guard !Task.isCancelled, let self, self.context === context else { return }
                    let next = self.record(fix)
                    if Self.movesGeoFilter(from: context.context, to: next) { context.update(next) }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            Self.logger.error("start failed: \(error.localizedDescription, privacy: .public)")
            await tearDown()
            phase = .idle
        }
    }

    /// Ends a running session and waits for the engine to drain. Ignored while starting: the screen hides Stop
    /// until the microphone is running.
    func stop() async {
        guard phase == .listening else { return }
        phase = .stopping
        await tearDown()
        phase = .idle
    }

    // MARK: - Private

    private func handle(_ event: IdentificationEvent) {
        switch event {
        case .window(let report):
            windowsScored += 1
            lastWindow = report
        case .stack(let stack):
            self.stack = stack
            list.update(with: stack)
            onStack(stack)
        }
    }

    /// The engine's stream ended on its own: the source stopped, or a model call failed.
    private func sessionEnded() {
        guard phase == .listening else { return }
        locationTask?.cancel()
        locationTask = nil
        source = nil
        eventTask = nil
        phase = .idle
    }

    private func tearDown() async {
        locationTask?.cancel()
        locationTask = nil
        await source?.stop()
        source = nil
        // The engine finishes its stream once the source's chunks end; wait so nothing lands after Stop.
        let events = eventTask
        eventTask = nil
        await events?.value
    }

    /// Records what the location stream delivered and returns what the engine would filter by from now on. No
    /// fix after a fix keeps the earlier one rather than dropping the filter; no fix at all means no geo filter.
    private func record(_ fix: LocationFix) -> GeoContext? {
        if case .unavailable = fix, case .settled(.fix) = locationState {
            // Keep the earlier fix on screen and in the engine.
        } else {
            locationState = .settled(fix)
        }
        guard case .settled(.fix(let latitude, let longitude, _, _)) = locationState else { return nil }
        return GeoContext(latitude: latitude, longitude: longitude, date: .now)
    }

    /// One reader over the run's location stream, so the first element that settles Start and the rest the run
    /// reads come through the same iterator (an `AsyncStream` supports one).
    private final class FixReader {
        private var iterator: AsyncStream<LocationFix>.AsyncIterator

        init(_ stream: AsyncStream<LocationFix>) {
            iterator = stream.makeAsyncIterator()
        }

        func next() async -> LocationFix? {
            // The iterator is taken out for the await: a mutating async call on an isolated property is not allowed.
            var reading = iterator
            let fix = await reading.next(isolation: #isolation)
            iterator = reading
            return fix
        }
    }

    /// Whether the engine's filter should change: gaining or losing a place, or moving more than
    /// `geoFilterMoveThreshold`. A step of a few hundred metres changes nothing in the species prior.
    static func movesGeoFilter(from current: GeoContext?, to next: GeoContext?) -> Bool {
        switch (current, next) {
        case (nil, nil): return false
        case (nil, .some), (.some, nil): return true
        case (.some(let current), .some(let next)):
            let here = CLLocation(latitude: current.latitude, longitude: current.longitude)
            return here.distance(from: CLLocation(latitude: next.latitude, longitude: next.longitude)) > geoFilterMoveThreshold
        }
    }
}
