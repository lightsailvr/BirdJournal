import Foundation
import OnnxRuntimeBindings
import Synchronization

public enum ModelError: Error {
    case resourceMissing(String)
    case unexpectedOutput(name: String)
    case classCountMismatch(model: Int, labels: Int)
}

/// One ONNX Runtime environment for the process; sessions share it. ORTEnv is thread-safe but not marked
/// Sendable, so it sits behind a lock and sessions are created inside it.
enum ONNXRuntime {
    private static let environment: Mutex<ORTEnv> = {
        do {
            return Mutex(try ORTEnv(loggingLevel: .warning))
        } catch {
            fatalError("ONNX Runtime environment failed to initialize: \(error)")
        }
    }()

    static func makeSession(modelPath: String) throws -> ORTSession {
        try environment.withLock { env in
            try ORTSession(env: env, modelPath: modelPath, sessionOptions: try ORTSessionOptions())
        }
    }

    /// Runs `session` on one float tensor of `shape` and returns the named float output.
    static func run(_ session: ORTSession, input: String, values: [Float], shape: [Int], output: String) throws -> [Float] {
        let data = values.withUnsafeBufferPointer { NSMutableData(bytes: $0.baseAddress, length: $0.count * MemoryLayout<Float>.size) }
        let tensor = try ORTValue(tensorData: data, elementType: .float, shape: shape.map { NSNumber(value: $0) })
        let outputs = try session.run(withInputs: [input: tensor], outputNames: [output], runOptions: nil)
        guard let value = outputs[output] else { throw ModelError.unexpectedOutput(name: output) }
        let bytes = try value.tensorData() as Data
        return bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// A file inside the package's `Models` resource folder (the symlink to the repo's `models/` directory).
    static func bundledModelURL(_ name: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Models") else {
            throw ModelError.resourceMissing(name)
        }
        return url
    }
}

/// BirdNET+ V3.0 through ONNX Runtime: raw 32 kHz waveform in, per-class sigmoid scores out.
public final class ONNXBirdModel: BirdModel, @unchecked Sendable {
    public static let modelFileName = "BirdNET+_V3.0-preview3.1_Global_11K_FP16_pruned.onnx"
    public static let labelsFileName = "BirdNET+_V3.0-preview3.1_Global_11K_Labels.csv"

    public let species: [Species]
    public let sampleRate = 32_000

    /// ORTSession.run is thread-safe, but serializing calls keeps one window's inference from slowing another's.
    private let session: Mutex<ORTSession>

    public init(modelURL: URL, labelsURL: URL) throws {
        species = try AcousticLabels.load(from: labelsURL)
        session = Mutex(try ONNXRuntime.makeSession(modelPath: modelURL.path))
    }

    /// The model files shipped in the package resource bundle.
    public static func bundled() throws -> ONNXBirdModel {
        try ONNXBirdModel(modelURL: ONNXRuntime.bundledModelURL(modelFileName), labelsURL: ONNXRuntime.bundledModelURL(labelsFileName))
    }

    public func scores(for samples: [Float]) throws -> [Float] {
        let scores = try session.withLock { session in
            try ONNXRuntime.run(session, input: "input", values: samples, shape: [1, samples.count], output: "predictions")
        }
        guard scores.count == species.count else { throw ModelError.classCountMismatch(model: scores.count, labels: species.count) }
        return scores
    }
}

/// BirdNET geomodel v3.0.4 through ONNX Runtime: (latitude, longitude, week) in, per-class occurrence out.
public final class ONNXGeoModel: SpeciesOccurrenceModel, @unchecked Sendable {
    public static let modelFileName = "BirdNET+_Geomodel_V3.0.4_Global_14K_FP16.onnx"
    public static let labelsFileName = "BirdNET+_Geomodel_V3.0.4_Global_14K_Labels.txt"

    public let labels: [GeoLabel]
    private let session: Mutex<ORTSession>

    public init(modelURL: URL, labelsURL: URL) throws {
        labels = try GeoLabels.load(from: labelsURL)
        session = Mutex(try ONNXRuntime.makeSession(modelPath: modelURL.path))
    }

    public static func bundled() throws -> ONNXGeoModel {
        try ONNXGeoModel(modelURL: ONNXRuntime.bundledModelURL(modelFileName), labelsURL: ONNXRuntime.bundledModelURL(labelsFileName))
    }

    public func occurrence(in context: GeoContext) throws -> [String: Float] {
        let input = [Float(context.latitude), Float(context.longitude), Float(context.week)]
        let probabilities = try session.withLock { session in
            try ONNXRuntime.run(session, input: "input", values: input, shape: [1, 3], output: "probabilities")
        }
        guard probabilities.count == labels.count else { throw ModelError.classCountMismatch(model: probabilities.count, labels: labels.count) }
        var result: [String: Float] = [:]
        result.reserveCapacity(labels.count)
        for (label, probability) in zip(labels, probabilities) { result[label.scientificName] = probability }
        return result
    }
}
