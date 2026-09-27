import Identification

/// The engine over the bundled BirdNET+ models, loaded once per process off the main actor (the acoustic model
/// is 70 MB) and shared by every listening session.
enum BundledIdentification {
    private static var loading: Task<IdentificationEngine, any Error>?

    static func engine() async throws -> IdentificationEngine {
        if let loading { return try await loading.value }
        let task = Task.detached(priority: .userInitiated) {
            IdentificationEngine(model: try ONNXBirdModel.bundled(), occurrenceModel: try ONNXGeoModel.bundled())
        }
        loading = task
        do {
            return try await task.value
        } catch {
            loading = nil  // a failed load (missing model files) is retried on the next start
            throw error
        }
    }
}
