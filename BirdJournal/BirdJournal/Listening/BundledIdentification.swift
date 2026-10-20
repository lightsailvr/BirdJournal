import Identification
import OSLog
import Synchronization

/// The engine over the bundled BirdNET+ models, loaded once per process off the main actor (the acoustic model
/// is 70 MB) and shared by every listening session.
enum BundledIdentification {
    private static var loading: Task<IdentificationEngine, any Error>?

    /// The bundled geomodel, shared by the engine and the rarity reader so it is loaded once.
    nonisolated static let geoModel = SharedGeoModel()

    static func engine() async throws -> IdentificationEngine {
        if let loading { return try await loading.value }
        let task = Task.detached(priority: .userInitiated) {
            IdentificationEngine(model: try ONNXBirdModel.bundled(), occurrenceModel: try geoModel.loaded())
        }
        loading = task
        do {
            return try await task.value
        } catch {
            loading = nil  // a failed load (missing model files) is retried on the next start
            throw error
        }
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
