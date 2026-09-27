import AVFAudio
import Testing
@testable import Identification

// Every AudioSource hands the engine the same chunk shape: mono Float samples plus the source's sample rate
// (spec "Architecture: three modules behind two seams"). Glasses and phone mic both arrive as AVAudioPCMBuffer.
@Suite("AudioChunk from AVAudioPCMBuffer")
struct AudioChunkTests {
    @Test("mono Float32 samples pass through unchanged")
    func monoFloat() throws {
        let buffer = try makeBuffer(format: .pcmFormatFloat32, channels: 1, interleaved: false, rate: 48_000)
        fill(buffer, float: [[0.5, -0.25, 1]])

        let chunk = try #require(AudioChunk(buffer: buffer, presentationTime: 12.5))

        #expect(chunk.samples == [0.5, -0.25, 1])
        #expect(chunk.sampleRate == 48_000)
        #expect(chunk.presentationTime == 12.5)
    }

    @Test("stereo Float32 is averaged down to mono")
    func stereoFloatDownmix() throws {
        let buffer = try makeBuffer(format: .pcmFormatFloat32, channels: 2, interleaved: false, rate: 44_100)
        fill(buffer, float: [[1, 0, -1], [0, 0, 1]])

        let chunk = try #require(AudioChunk(buffer: buffer, presentationTime: 0))

        #expect(chunk.samples == [0.5, 0, 0])
        #expect(chunk.sampleRate == 44_100)
    }

    @Test("mono Int16 is scaled to [-1, 1)")
    func monoInt16() throws {
        let buffer = try makeBuffer(format: .pcmFormatInt16, channels: 1, interleaved: false, rate: 16_000)
        fill(buffer, int16: [[Int16.min, 0, 16_384]])

        let chunk = try #require(AudioChunk(buffer: buffer, presentationTime: 0))

        #expect(chunk.samples == [-1, 0, 0.5])
    }

    @Test("interleaved stereo Int16 is scaled and averaged")
    func interleavedInt16() throws {
        let buffer = try makeBuffer(format: .pcmFormatInt16, channels: 2, interleaved: true, rate: 48_000)
        // Frames: (L, R) = (16384, 0), (-16384, -16384)
        let data = try #require(buffer.int16ChannelData)
        for (i, value) in [Int16(16_384), 0, -16_384, -16_384].enumerated() { data[0][i] = value }
        buffer.frameLength = 2

        let chunk = try #require(AudioChunk(buffer: buffer, presentationTime: 0))

        #expect(chunk.samples == [0.25, -0.5])
    }

    @Test("duration is frame count over sample rate")
    func duration() {
        let chunk = AudioChunk(samples: [Float](repeating: 0, count: 24_000), sampleRate: 48_000, presentationTime: 0)
        #expect(chunk.duration == 0.5)
    }

    // MARK: - Helpers

    private func makeBuffer(format: AVAudioCommonFormat, channels: AVAudioChannelCount, interleaved: Bool, rate: Double) throws -> AVAudioPCMBuffer {
        let audioFormat = try #require(AVAudioFormat(commonFormat: format, sampleRate: rate, channels: channels, interleaved: interleaved))
        return try #require(AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: 16))
    }

    private func fill(_ buffer: AVAudioPCMBuffer, float channels: [[Float]]) {
        for (c, samples) in channels.enumerated() {
            for (i, sample) in samples.enumerated() { buffer.floatChannelData![c][i] = sample }
        }
        buffer.frameLength = AVAudioFrameCount(channels[0].count)
    }

    private func fill(_ buffer: AVAudioPCMBuffer, int16 channels: [[Int16]]) {
        for (c, samples) in channels.enumerated() {
            for (i, sample) in samples.enumerated() { buffer.int16ChannelData![c][i] = sample }
        }
        buffer.frameLength = AVAudioFrameCount(channels[0].count)
    }
}
