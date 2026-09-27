import CoreMedia
import Identification
import MWDATCamera
import MWDATCore
import Observation
import UIKit

/// Which `AudioSource` a spike run listens to.
enum SpikeSourceKind: String, CaseIterable, Identifiable {
    case glasses
    case phoneMic

    var id: Self { self }

    var title: String {
        switch self {
        case .glasses: "Glasses"
        case .phoneMic: "Phone mic"
        }
    }
}

/// Phase A audio spike (issue #3): runs one `AudioSource` and logs audio cadence, latency, glasses battery,
/// charging and thermal level every 30 seconds, plus every gap over 2 s, session and stream state change, and
/// app lifecycle change (background, lock) as it happens.
///
/// Arrival times use the host clock, the same clock `AVAudioTime` host times use, so for the phone mic the
/// logged first offset is the absolute capture-to-delivery latency.
@Observable
final class SpikeRecorder {
    static let summaryInterval: Duration = .seconds(30)

    /// True from Start until the source is streaming or has failed; Stop waits for it.
    private(set) var isStarting = false
    private(set) var isRunning = false
    private(set) var logURL: URL?
    /// Every spike log on the phone, newest first, so a run the system killed can still be shared.
    private(set) var logFiles: [URL] = []
    private(set) var latestSummary: CadenceSummary?
    private(set) var recentLines: [String] = []
    var errorMessage: String?

    @ObservationIgnored private let connection: GlassesConnection
    @ObservationIgnored private var source: (any AudioSource)?
    @ObservationIgnored private var log: SpikeLog?
    @ObservationIgnored private var monitor = AudioCadenceMonitor(startedAt: 0)
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var sessionState = "-"
    @ObservationIgnored private var streamState = "-"
    @ObservationIgnored private var receivedFirstChunk = false
    /// Whether the session or stream reported `.paused` since the last chunk; tells a pause from a dropout.
    @ObservationIgnored private var pausedSinceLastChunk = false
    @ObservationIgnored private var lifecycleObservers: [any NSObjectProtocol] = []

    init(connection: GlassesConnection) {
        self.connection = connection
        refreshLogFiles()
    }

    /// Starts a run. `sampleRate` applies to the glasses source; the phone mic runs at its native rate.
    func start(_ kind: SpikeSourceKind, sampleRate: AudioSampleRate = .rate48000) async {
        guard !isRunning else { return }
        errorMessage = nil
        do {
            let log = try SpikeLog(startedAt: .now)
            self.log = log
            logURL = log.url
        } catch {
            errorMessage = "Could not create the log file: \(error.localizedDescription)"
            return
        }
        isRunning = true
        isStarting = true
        defer { isStarting = false }
        refreshLogFiles()
        UIDevice.current.isBatteryMonitoringEnabled = true
        sessionState = "-"
        streamState = "-"
        receivedFirstChunk = false
        pausedSinceLastChunk = false

        let source: any AudioSource
        switch kind {
        case .glasses:
            let glasses = GlassesAudioSource(sampleRate: sampleRate)
            source = glasses
            write("start", [("source", kind.rawValue), ("sample_rate", "\(glasses.sampleRate.rawValue)"),
                            ("resolution", "\(glasses.configuration.resolution)"),
                            ("fps", "\(glasses.configuration.frameRate)"), ("app", appVersion)])
            tasks.append(Task { [weak self] in
                for await event in glasses.events { self?.handle(event) }
            })
        case .phoneMic:
            source = PhoneMicAudioSource()
            write("start", [("source", kind.rawValue), ("app", appVersion)])
        }
        self.source = source
        observeLifecycle()

        let startedAt = Self.now
        monitor = AudioCadenceMonitor(startedAt: startedAt)
        do {
            let chunks = try await source.start()
            write("source_started", [("after_s", format(Self.now - startedAt))])
            tasks.append(Task { [weak self] in
                for await chunk in chunks { self?.receive(chunk) }
                self?.write("chunks_ended")
            })
            tasks.append(Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.summaryInterval)
                    guard !Task.isCancelled else { return }
                    self?.writeSummary()
                }
            })
        } catch {
            write("start_failed", [("error", quoted(error.localizedDescription))])
            errorMessage = error.localizedDescription
            connection.noteSessionFailure(error)
            await finish()
        }
    }

    /// Ends the run. Ignored while starting, so a half-started source is never orphaned.
    func stop() async {
        guard isRunning, !isStarting else { return }
        await finish()
    }

    private func finish() async {
        if let gap = monitor.openGap(at: Self.now) {
            write("gap_open", [("duration_s", format(gap.duration))])
        }
        writeSummary()
        await source?.stop()
        source = nil
        tasks.forEach { $0.cancel() }
        tasks = []
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
        lifecycleObservers = []
        write("stop")
        log?.close()
        log = nil
        isRunning = false
        refreshLogFiles()
    }

    private func refreshLogFiles() {
        let files = (try? FileManager.default.contentsOfDirectory(at: SpikeLog.directory, includingPropertiesForKeys: nil)) ?? []
        // Names embed the start time, so reverse name order is newest first.
        logFiles = files.filter { $0.pathExtension == "log" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    // MARK: - Audio

    private func receive(_ chunk: AudioChunk) {
        let now = Self.now
        if !receivedFirstChunk {
            receivedFirstChunk = true
            write("first_chunk", [("samples", "\(chunk.samples.count)"), ("sample_rate", "\(chunk.sampleRate)"),
                                  ("offset_s", format(now - chunk.presentationTime))])
        }
        if let gap = monitor.record(chunk, arrivedAt: now) {
            write("gap", [("duration_s", format(gap.duration)), ("paused", pausedSinceLastChunk ? "yes" : "no"),
                          ("app", appState)])
        }
        pausedSinceLastChunk = false
    }

    private func writeSummary() {
        let summary = monitor.summarize(at: Self.now)
        latestSummary = summary
        let glasses = connection.connectedDevice?.state
        let phoneBattery = UIDevice.current.batteryLevel
        write("status", [
            ("chunks", "\(summary.chunks)"),
            ("audio_s", format(summary.audioSeconds)),
            ("wall_s", format(summary.wallSeconds)),
            ("mean_interval_ms", milliseconds(summary.meanInterval)),
            ("max_interval_ms", milliseconds(summary.maxInterval)),
            ("gaps", "\(summary.gaps)"),
            ("latency_mean_ms", milliseconds(summary.latencyMean)),
            ("latency_max_ms", milliseconds(summary.latencyMax)),
            ("since_last_s", summary.secondsSinceLastChunk.map(format) ?? "-"),
            ("total_chunks", "\(summary.totalChunks)"),
            ("total_gaps", "\(summary.totalGaps)"),
            ("glasses_battery", glasses?.batteryLevel.map { "\($0)" } ?? "-"),
            ("glasses_charging", glasses.map { "\($0.chargingState)" } ?? "-"),
            ("glasses_thermal", glasses.map { "\($0.thermalLevel)" } ?? "-"),
            ("glasses_don", glasses.map { "\($0.donState)" } ?? "-"),
            ("glasses_link", glasses.map { "\($0.linkState)" } ?? "-"),
            ("session", sessionState),
            ("stream", streamState),
            ("phone_battery", phoneBattery < 0 ? "-" : "\(Int((phoneBattery * 100).rounded()))"),
            ("phone_charging", "\(UIDevice.current.batteryState)"),
            ("phone_thermal", "\(ProcessInfo.processInfo.thermalState)"),
            ("app", appState),
        ])
    }

    // MARK: - Events

    private func handle(_ event: GlassesAudioSource.Event) {
        switch event {
        case .sessionState(let state):
            sessionState = "\(state)"
            if state == .paused { pausedSinceLastChunk = true }
            write("session_state", [("state", sessionState)])
        case .sessionError(let error):
            connection.noteSessionFailure(error)
            write("session_error", [("error", quoted(error.description))])
        case .streamState(let state):
            streamState = "\(state)"
            if state == .paused { pausedSinceLastChunk = true }
            write("stream_state", [("state", streamState)])
        case .streamError(let error):
            write("stream_error", [("error", quoted(error.description))])
        }
    }

    private func observeLifecycle() {
        let names: [(Notification.Name, String)] = [
            (UIApplication.didEnterBackgroundNotification, "background"),
            (UIApplication.willEnterForegroundNotification, "foreground"),
            (UIApplication.protectedDataWillBecomeUnavailableNotification, "locked"),
            (UIApplication.protectedDataDidBecomeAvailableNotification, "unlocked"),
            (ProcessInfo.thermalStateDidChangeNotification, "phone_thermal_changed"),
        ]
        for (name, event) in names {
            let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.write("app_\(event)") }
            }
            lifecycleObservers.append(observer)
        }
    }

    // MARK: - Formatting

    private func write(_ event: String, _ fields: [(String, String)] = []) {
        guard let line = log?.write(event, fields) else { return }
        recentLines.append(line)
        if recentLines.count > 100 { recentLines.removeFirst(recentLines.count - 100) }
    }

    private static var now: Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    private var appState: String {
        switch UIApplication.shared.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        case .background: UIApplication.shared.isProtectedDataAvailable ? "background" : "background_locked"
        @unknown default: "unknown"
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?")(\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    // Fixed "%f" formats keep the log parseable whatever the phone's locale.
    private func format(_ seconds: Double) -> String { String(format: "%.3f", seconds) }

    private func milliseconds(_ seconds: Double?) -> String {
        seconds.map { String(format: "%.1f", $0 * 1_000) } ?? "-"
    }

    private func quoted(_ text: String) -> String { "\"\(text.replacing("\"", with: "'"))\"" }
}
