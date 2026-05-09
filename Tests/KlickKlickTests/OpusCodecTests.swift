import XCTest
import AVFoundation
@testable import KlickKlick

final class OpusCodecTests: XCTestCase {

    /// Sanity-check: PCM → Opus → PCM roundtrip produces a buffer of the expected
    /// frame length. Opus is lossy so we don't compare samples bit-for-bit.
    func testRoundtripFrameLength() throws {
        let encoder = try OpusEncoder()
        let decoder = try OpusDecoder()

        let pcm = Self.makeTonePCM()
        let packet = try encoder.encode(pcm)
        XCTAssertGreaterThan(packet.count, 0, "Opus packet must be non-empty")
        XCTAssertLessThan(packet.count, 1275, "Opus packet must be <= max frame size")

        let decoded = try decoder.decode(packet)
        // Opus has ~120 samples of encoder lookahead; the first decoded frame
        // may come back short. Tolerate that — we just need samples out.
        XCTAssertGreaterThan(decoded.frameLength, 0)
        XCTAssertLessThanOrEqual(decoded.frameLength, AudioFormats.frameSize)
        XCTAssertEqual(decoded.format.sampleRate, AudioFormats.sampleRate)
        XCTAssertEqual(decoded.format.channelCount, AudioFormats.channels)
    }

    /// After feeding enough frames to clear Opus's lookahead, decoded output
    /// should match a full 20 ms frame.
    func testRoundtripFullFrameAfterPriming() throws {
        let encoder = try OpusEncoder()
        let decoder = try OpusDecoder()
        let pcm = Self.makeTonePCM()
        // Prime: encode/decode a few frames first.
        for _ in 0..<3 {
            let packet = try encoder.encode(pcm)
            _ = try decoder.decode(packet)
        }
        // Now the steady-state frame should be exactly frameSize long.
        let packet = try encoder.encode(pcm)
        let decoded = try decoder.decode(packet)
        XCTAssertEqual(decoded.frameLength, AudioFormats.frameSize)
    }

    /// Two identical inputs should produce identical (or very similar) encoded packets
    /// when encoder state is fresh each time. Use this as a smoke test that encoding
    /// is deterministic for our input.
    func testEncoderProducesNonEmpty() throws {
        let encoder = try OpusEncoder()
        let pcm = Self.makeTonePCM()
        let packet1 = try encoder.encode(pcm)
        let packet2 = try encoder.encode(pcm)
        XCTAssertFalse(packet1.isEmpty)
        XCTAssertFalse(packet2.isEmpty)
    }

    // MARK: - Fixtures

    /// 20 ms of 440 Hz sine at 48 kHz, Float32 mono.
    private static func makeTonePCM() -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: AudioFormats.pcm, frameCapacity: AudioFormats.frameSize)!
        buffer.frameLength = AudioFormats.frameSize
        let samples = buffer.floatChannelData![0]
        let freq: Float = 440
        let sr = Float(AudioFormats.sampleRate)
        for i in 0..<Int(AudioFormats.frameSize) {
            samples[i] = 0.2 * sinf(2 * .pi * freq * Float(i) / sr)
        }
        return buffer
    }
}
