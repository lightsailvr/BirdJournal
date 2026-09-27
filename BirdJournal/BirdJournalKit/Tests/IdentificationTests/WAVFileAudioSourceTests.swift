import Foundation
import Testing
@testable import Identification

@Suite("WAVFileAudioSource")
struct WAVFileAudioSourceTests {
    @Test("the synthetic fixture streams as 44.1 kHz mono chunks that add up to six seconds")
    func streamsFixture() async throws {
        let source = WAVFileAudioSource(url: try Fixtures.url("synthetic-chirps-44k1.wav"), chunkFrames: 4_096)

        var chunks: [AudioChunk] = []
        for await chunk in try await source.start() { chunks.append(chunk) }

        #expect(chunks.count == 65)  // ceil(264,600 / 4,096)
        #expect(chunks.allSatisfy { $0.sampleRate == 44_100 })
        #expect(chunks.reduce(0) { $0 + $1.samples.count } == 6 * 44_100)
        #expect(chunks.first?.presentationTime == 0)
        #expect(chunks[1].presentationTime == 4_096.0 / 44_100.0, "second chunk at \(chunks[1].presentationTime)")
        #expect(chunks.last!.samples.count == 264_600 % 4_096)
        #expect(chunks.flatMap(\.samples).max()! > 0.2)
    }

    @Test("a missing file fails at start")
    func missingFile() async {
        let source = WAVFileAudioSource(url: URL(fileURLWithPath: "/nonexistent/clip.wav"))
        await #expect(throws: (any Error).self) { try await source.start() }
    }

    @Test("starting twice is rejected until stopped")
    func doubleStart() async throws {
        let source = WAVFileAudioSource(url: try Fixtures.url("noise-44k1.wav"))
        _ = try await source.start()
        await #expect(throws: WAVFileAudioSource.SourceError.self) { try await source.start() }
        await source.stop()
        _ = try await source.start()
        await source.stop()
    }
}

enum Fixtures {
    static func url(_ name: String) throws -> URL {
        let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
        return try #require(Bundle.module.url(forResource: parts[0], withExtension: parts[1], subdirectory: "Fixtures"))
    }
}
