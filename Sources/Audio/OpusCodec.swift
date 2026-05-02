@preconcurrency import AVFoundation

enum OpusCodecError: Error {
    case converterInitFailed
    case encodeFailed(OSStatus)
    case decodeFailed(OSStatus)
    case underlying(Error)
    case emptyPacket
    case bufferAllocFailed
}

/// Wraps AVAudioConverter for PCM → Opus encoding.
///
/// Input:  AVAudioPCMBuffer in `AudioFormats.pcm`, `frameSize` frames (20 ms @ 48 kHz).
/// Output: `Data` containing a single Opus packet (~40–200 bytes at VOIP bitrates).
final class OpusEncoder {
    private let converter: AVAudioConverter
    private let compressed: AVAudioCompressedBuffer
    /// Upper bound on encoded Opus packet size; Opus spec caps at 1275 bytes per frame.
    private let maxPacketSize: Int = 1500

    init(bitrate: Int = 16_000) throws {
        guard let c = AVAudioConverter(from: AudioFormats.pcm, to: AudioFormats.opus) else {
            throw OpusCodecError.converterInitFailed
        }
        c.bitRate = bitrate
        self.converter = c
        self.compressed = AVAudioCompressedBuffer(
            format: AudioFormats.opus,
            packetCapacity: 1,
            maximumPacketSize: maxPacketSize
        )
    }

    /// Encode one 20 ms PCM buffer into a single Opus packet.
    func encode(_ pcm: AVAudioPCMBuffer) throws -> Data {
        compressed.packetCount = 0
        compressed.byteLength = 0

        let providedInput = MutableBox(false)
        var status: NSError?

        let result = converter.convert(to: compressed, error: &status) { _, outStatus in
            if providedInput.value {
                outStatus.pointee = .noDataNow
                return nil
            }
            providedInput.value = true
            outStatus.pointee = .haveData
            return pcm
        }

        if let status { throw OpusCodecError.underlying(status) }
        guard result != .error else { throw OpusCodecError.encodeFailed(-1) }
        guard compressed.packetCount >= 1, compressed.byteLength > 0 else {
            throw OpusCodecError.emptyPacket
        }

        let ptr = compressed.data.assumingMemoryBound(to: UInt8.self)
        return Data(bytes: ptr, count: Int(compressed.byteLength))
    }
}

/// Wraps AVAudioConverter for Opus → PCM decoding.
final class OpusDecoder {
    private let converter: AVAudioConverter

    init() throws {
        guard let c = AVAudioConverter(from: AudioFormats.opus, to: AudioFormats.pcm) else {
            throw OpusCodecError.converterInitFailed
        }
        self.converter = c
    }

    /// Decode one Opus packet into a PCM buffer of `AudioFormats.frameSize` frames.
    func decode(_ opusPacket: Data) throws -> AVAudioPCMBuffer {
        guard !opusPacket.isEmpty else { throw OpusCodecError.emptyPacket }

        let input = AVAudioCompressedBuffer(
            format: AudioFormats.opus,
            packetCapacity: 1,
            maximumPacketSize: opusPacket.count
        )
        input.byteLength = UInt32(opusPacket.count)
        input.packetCount = 1
        input.packetDescriptions?.pointee = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 0,
            mDataByteSize: UInt32(opusPacket.count)
        )
        opusPacket.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            input.data.copyMemory(from: base, byteCount: opusPacket.count)
        }

        guard let output = AVAudioPCMBuffer(
            pcmFormat: AudioFormats.pcm,
            frameCapacity: AudioFormats.frameSize
        ) else {
            throw OpusCodecError.bufferAllocFailed
        }

        let delivered = MutableBox(false)
        var status: NSError?
        let result = converter.convert(to: output, error: &status) { _, outStatus in
            if delivered.value {
                outStatus.pointee = .noDataNow
                return nil
            }
            delivered.value = true
            outStatus.pointee = .haveData
            return input
        }

        if let status { throw OpusCodecError.underlying(status) }
        guard result != .error else { throw OpusCodecError.decodeFailed(-1) }
        return output
    }
}
