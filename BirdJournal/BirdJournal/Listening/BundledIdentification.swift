import Identification
import OSLog
import Synchronization
import UIKit

/// The engine over the bundled BirdNET+ models, loaded off the main actor (the acoustic model is 70 MB), ahead of a run
/// when Listen appears, and shared by every listening session. The geomodel stays through a memory warning: it's 8 MB,
/// and the rarity reader uses it as well.
enum BundledIdentification {
    /// The engine, loaded once and kept, until the system asks for its memory back.
    private static let engineLoader = WarmLoader<IdentificationEngine>(dropsOn: UIApplication.didReceiveMemoryWarningNotification) {
        #if DEBUG
        let started = ContinuousClock.now
        defer { print("SPEED engine-load ms=\((ContinuousClock.now - started).speedMilliseconds)") }
        #endif
        return IdentificationEngine(model: try ONNXBirdModel.bundled(), occurrenceModel: try geoModel.loaded())
    }

    /// The bundled geomodel, shared by the engine and the rarity reader so it is loaded once.
    nonisolated static let geoModel = SharedGeoModel()

    static func engine() async throws -> IdentificationEngine {
        try await engineLoader.value()
    }

    /// Starts the engine loading at low priority, so Start doesn't wait for it (issue #150).
    static func warm() {
        engineLoader.warm()
    }

    /// Reads a card's rarity at the add (issue #52) from the shared geomodel under the committed calibration; nil when
    /// the calibration is missing, so sightings are still recorded, without rarity.
    static func rarityReader() -> RarityReader? {
        do {
            return RarityReader(occurrenceModel: geoModel, calibration: try RarityCalibration.bundled())
        } catch {
            Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "album").error("no rarity calibration: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

/// Something heavy, loaded off the main actor once and kept (issue #150). `warm` loads it ahead of need at low priority, and
/// asking for the `value` while that's under way waits for the same load and raises its priority. A failed load is
/// forgotten, so the next asking tries again. Under memory pressure it forgets what it has loaded: a run under way keeps its
/// own reference, the memory goes when the run ends, and the next asking loads it again. A load under way carries on, since
/// forgetting it would only start a second one beside it.
final class WarmLoader<Value: Sendable> {
    private let load: @Sendable () throws -> Value
    private var loading: Task<Value, any Error>?
    private var isLoaded = false
    private var pressure: (any NSObjectProtocol)?
    private let center: NotificationCenter

    /// - Parameter notification: the notification that means memory is short.
    init(dropsOn notification: Notification.Name, center: NotificationCenter = .default, load: @escaping @Sendable () throws -> Value) {
        self.load = load
        self.center = center
        pressure = center.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.drop() }
        }
    }

    isolated deinit {
        if let pressure { center.removeObserver(pressure) }
    }

    /// The loaded value, loading it now if nothing has.
    func value() async throws -> Value {
        let task = loading ?? start(priority: .userInitiated)
        let value = try await task.value
        if loading == task { isLoaded = true }
        return value
    }

    /// Starts the load at low priority, if nothing has.
    func warm() {
        if loading == nil { _ = start(priority: .utility) }
    }

    private func drop() {
        guard isLoaded else { return }
        loading = nil
        isLoaded = false
    }

    private func start(priority: TaskPriority) -> Task<Value, any Error> {
        let task = Task.detached(priority: priority) { [load] in try load() }
        loading = task
        // At the load's own priority: waiting on it from anything higher would raise it.
        Task(priority: priority) { [weak self] in
            let result = await task.result
            guard let self, loading == task else { return }
            if case .failure = result { loading = nil } else { isLoaded = true }
        }
        return task
    }
}

/// The bundled geomodel, loaded on first use (a run's engine, or the first rarity read) and kept; a failed load is
/// retried on the next use.
nonisolated final class SharedGeoModel: SpeciesOccurrenceModel {
    private let model = Mutex<ONNXGeoModel?>(nil)

    func loaded() throws -> ONNXGeoModel {
        try model.withLock { model in
            if let model { return model }
            let loaded = try ONNXGeoModel.bundled()
            model = loaded
            return loaded
        }
    }

    func occurrence(in context: GeoContext) throws -> [String: Float] {
        try loaded().occurrence(in: context)
    }
}
