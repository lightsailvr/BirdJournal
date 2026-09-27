import Foundation
import Testing
@testable import Identification

// The glasses stream at 44.1 kHz and the phone mic at whatever the input node reports; BirdNET+ V3.0 wants 32 kHz.
@Suite("AudioResampler")
struct AudioResamplerTests {
    @Test("a 1 kHz tone at 44.1 kHz comes out as about one second of 1 kHz at 32 kHz, chunk by chunk")
    func toneDownsampled() throws {
        let resampler = AudioResampler(outputRate: 32_000)
        let inputRate = 44_100
        var output: [Float] = []
        for chunkIndex in 0..<10 {
            let samples = (0..<4_410).map { i in sin(2 * Float.pi * 1_000 * Float(chunkIndex * 4_410 + i) / Float(inputRate)) }
            output += try resampler.resample(AudioChunk(samples: samples, sampleRate: inputRate, presentationTime: Double(chunkIndex) * 0.1))
        }

        // The converter holds its filter's worth of frames until the stream is flushed.
        #expect(abs(output.count - 32_000) < 400)
        output += try resampler.flush()
        #expect(output.count == 32_000)
        // Zero crossings: a 1 kHz tone crosses zero 2,000 times per second.
        let crossings = zip(output, output.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
        let seconds = Double(output.count) / 32_000
        #expect(abs(Double(crossings) / seconds - 2_000) < 40)
        #expect(output.max()! > 0.9 && output.min()! < -0.9)
    }

    @Test("chunks already at the output rate pass through unchanged")
    func passThrough() throws {
        let resampler = AudioResampler(outputRate: 32_000)
        let chunk = AudioChunk(samples: [0.1, -0.2, 0.3], sampleRate: 32_000, presentationTime: 0)
        #expect(try resampler.resample(chunk) == [0.1, -0.2, 0.3])
    }

    @Test("a change of input rate drains the previous converter before switching, losing nothing")
    func rateChangeDrains() throws {
        let resampler = AudioResampler(outputRate: 32_000)
        var output = try resampler.resample(AudioChunk(samples: [Float](repeating: 0.5, count: 44_100), sampleRate: 44_100, presentationTime: 0))
        #expect(output.count < 32_000)
        output += try resampler.resample(AudioChunk(samples: [Float](repeating: 0.5, count: 48_000), sampleRate: 48_000, presentationTime: 1))
        output += try resampler.flush()
        #expect(output.count == 64_000)
    }

    @Test("flushing before any conversion yields nothing")
    func flushWithoutInput() throws {
        #expect(try AudioResampler(outputRate: 32_000).flush().isEmpty)
    }

    @Test("an empty chunk yields nothing, since the first glasses chunk can be empty")
    func emptyChunk() throws {
        let resampler = AudioResampler(outputRate: 32_000)
        #expect(try resampler.resample(AudioChunk(samples: [], sampleRate: 44_100, presentationTime: 0)).isEmpty)
    }
}
