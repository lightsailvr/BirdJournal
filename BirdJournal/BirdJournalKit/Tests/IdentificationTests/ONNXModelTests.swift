import Foundation
import Testing
@testable import Identification

// The pinned models from models/manifest.json, loaded from the package resource bundle. These prove the runtime
// runs the FP16 graphs correctly on this platform: under ONNX Runtime 1.19.2 on macOS the acoustic model's
// embeddings collapsed to zero and every input scored the same, so "differs between inputs" is a real check.
@Suite("ONNX models", .serialized)
struct ONNXModelTests {
    static let la = GeoContext(latitude: 34.05, longitude: -118.25, week: 36)

    @Test("the acoustic model loads with one label per output class and scores in [0, 1]")
    func acousticModelShape() throws {
        let model = try ONNXBirdModel.bundled()
        #expect(model.species.count == 11_560)
        #expect(model.species[4_848].commonName == "House Finch")

        let scores = try model.scores(for: [Float](repeating: 0, count: 96_000))

        #expect(scores.count == 11_560)
        #expect(scores.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
    }

    @Test("silence, noise and a tone all stay below the window threshold and differ from one another")
    func nonBirdInputsScoreLow() throws {
        let model = try ONNXBirdModel.bundled()
        let silence = [Float](repeating: 0, count: 96_000)
        var generator = SeededGenerator(seed: 7)
        let noise = (0..<96_000).map { _ in Float.random(in: -0.1...0.1, using: &generator) }
        let tone = (0..<96_000).map { 0.5 * sin(2 * Float.pi * 4_000 * Float($0) / 32_000) }

        let silenceScores = try model.scores(for: silence)
        let noiseScores = try model.scores(for: noise)
        let toneScores = try model.scores(for: tone)

        #expect(silenceScores.max()! < 0.15)
        #expect(noiseScores.max()! < 0.15)
        #expect(toneScores.max()! < 0.15)
        #expect(noiseScores != toneScores)
    }

    @Test("the label sets join by scientific name; the bird classes the geomodel does not know are a known, stable set")
    func labelSetsJoin() throws {
        let birds = try ONNXBirdModel.bundled().species.filter { $0.taxonomicClass == Species.birds }
        let known = Set(try ONNXGeoModel.bundled().labels.map(\.scientificName))

        let unknown = birds.filter { !known.contains($0.scientificName) }

        // 394 of 9,834 bird classes (preview 3.1 vs geomodel 3.0.4) can never be admitted. A change here means one
        // of the pinned label files changed and the join needs another look.
        #expect(unknown.count == 394, "\(unknown.prefix(10).map(\.commonName))")
        #expect(known.contains("Haemorhous mexicanus"))
    }

    @Test("the geomodel puts House Finch in Los Angeles and keeps Common Blackbird and Chaffinch out")
    func geomodelLosAngeles() throws {
        let model = try ONNXGeoModel.bundled()
        #expect(model.labels.count == 14_082)

        let occurrence = try model.occurrence(in: Self.la)

        #expect(occurrence.count == 14_082)
        #expect(occurrence["Haemorhous mexicanus"]! >= 0.03)
        #expect(occurrence["Turdus merula"]! < 0.03)
        #expect(occurrence["Fringilla coelebs"]! < 0.03)
    }
}

/// Deterministic random numbers for fixtures (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
