import Foundation
import Identification
import Observation
import OSLog

/// One listening run on the phone with no glasses (issue #6): the phone microphone feeds the engine, the location
/// is fetched once at start and refreshed every ten minutes, and the live list on the screen follows the stack.
/// Stop ends the run. Reusable: `start()` after `stop()` begins a fresh session.
@Observable
final class PhoneListeningSession {
    enum Phase: Equatable {
        case idle
        case starting
        case listening
        case stopping
    }

    enum LocationState: Equatable {
        case unknown
        case requesting
        /// What the latest request came back with. `.denied` and `.unavailable` mean identification runs
        /// without the regional filter; a refresh that finds nothing keeps the earlier fix instead.
        case settled(LocationFix)
    }

    static let locationRefreshInterval: Duration = .seconds(600)
    private static let logger = Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "phone-listening")

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
    @ObservationIgnored private let locationRefreshInterval: Duration
    @ObservationIgnored private var source: (any AudioSource)?
    @ObservationIgnored private var context: LiveGeoContext?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(
        loadEngine: @escaping @Sendable () async throws -> IdentificationEngine = { try await BundledIdentification.engine() },
        makeSource: @escaping () -> any AudioSource = { PhoneMicAudioSource() },
        location: any LocationProvider = CoreLocationProvider(),
        locationRefreshInterval: Duration = PhoneListeningSession.locationRefreshInterval
    ) {
        self.loadEngine = loadEngine
        self.makeSource = makeSource
        self.location = location
        self.locationRefreshInterval = locationRefreshInterval
    }

    /// Loads the models and takes the first location fix side by side, then starts the microphone. On failure
    /// the session is idle again with `errorMessage` set.
    func start() async {
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
        let context = LiveGeoContext(record(await location.currentFix()))
        self.context = context
        do {
            let engine = try await loading
            let source = makeSource()
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
            refreshTask = Task { [weak self, locationRefreshInterval] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: locationRefreshInterval)
                    guard !Task.isCancelled, let self else { return }
                    let fix = await self.location.currentFix()
                    // Stop may have landed during the request; a stale result must not touch the next session.
                    guard !Task.isCancelled, self.context === context else { return }
                    context.update(self.record(fix))
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
        }
    }

    /// The engine's stream ended on its own: the source stopped, or a model call failed.
    private func sessionEnded() {
        guard phase == .listening else { return }
        refreshTask?.cancel()
        refreshTask = nil
        source = nil
        eventTask = nil
        phase = .idle
    }

    private func tearDown() async {
        refreshTask?.cancel()
        refreshTask = nil
        await source?.stop()
        source = nil
        // The engine finishes its stream once the source's chunks end; wait so nothing lands after Stop.
        let events = eventTask
        eventTask = nil
        await events?.value
    }

    /// Records what a location request came back with and returns what the engine should filter by from now
    /// on. A missed refresh keeps the earlier fix rather than dropping the filter; no fix means no geo filter.
    private func record(_ fix: LocationFix) -> GeoContext? {
        if case .unavailable = fix, case .settled(.fix) = locationState {
            // Keep the earlier fix on screen and in the engine.
        } else {
            locationState = .settled(fix)
        }
        guard case .settled(.fix(let latitude, let longitude, _)) = locationState else { return nil }
        return GeoContext(latitude: latitude, longitude: longitude, date: .now)
    }
}
