@preconcurrency import AVFoundation
import os

/// Captures microphone audio with AVAudioEngine, converts to 48 kHz mono
/// Float32, and emits 20 ms (960-sample) Opus-encoded frames.
///
/// Callbacks on `onFrame` fire on a background serial queue; do not touch UI
/// from inside without hopping to the main actor.
final class AudioCapture {
    private let engine = AVAudioEngine()
    private let encoder: OpusEncoder
    private let ring = FloatRingBuffer(capacity: Int(AudioFormats.frameSize) * 8)
    private var formatConverter: AVAudioConverter?
    private let log = Logger(subsystem: "com.klick.walkietalkie", category: "AudioCapture")

    /// Fires once per 20 ms frame of captured audio. Payload is the encoded Opus packet.
    var onFrame: ((Data) -> Void)?

    init() throws {
        self.encoder = try OpusEncoder()
    }

    func start() throws {
        try AudioSessionManager.shared.configureForPTT()
        try AudioSessionManager.shared.activate()

        let inputNode = engine.inputNode

        // Enable Apple's voice-processing IO on the mic path:
        //   • acoustic echo cancellation — so the loudspeaker output doesn't
        //     bleed back into the mic and get re-transmitted
        //   • automatic gain control + noise suppression for a cleaner signal
        //
        // We do this on the input node directly rather than via the session's
        // `.voiceChat` / `.videoChat` mode because those modes force the
        // session onto the ring-volume channel (quieter playback). Enabling
        // voice processing here gives us the same signal cleanup while
        // leaving playback on the media-volume channel.
        //
        // Must be called *before* installing a tap — changing voice-processing
        // state after tap install throws.
        if #available(iOS 13.0, *) {
            do {
                try inputNode.setVoiceProcessingEnabled(true)
            } catch {
                log.error("Voice processing enable failed: \(String(describing: error))")
                // Non-fatal — mic still works, just without echo cancellation.
            }
        }

        let hwFormat = inputNode.outputFormat(forBus: 0)

        // If hardware format differs from our target, build a PCM→PCM converter.
        if hwFormat != AudioFormats.pcm {
            formatConverter = AVAudioConverter(from: hwFormat, to: AudioFormats.pcm)
        } else {
            formatConverter = nil
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buffer, _ in
            self?.handleInput(buffer)
        }

        engine.prepare()
        try engine.start()
        log.info("Capture started at hw sr=\(hwFormat.sampleRate), ch=\(hwFormat.channelCount)")
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func handleInput(_ buffer: AVAudioPCMBuffer) {
        // Step 1: convert to target PCM if needed.
        let targetBuffer: AVAudioPCMBuffer
        if let conv = formatConverter {
            // Estimate output frame capacity: frames * (targetSR / sourceSR) + slack.
            let ratio = AudioFormats.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: AudioFormats.pcm, frameCapacity: capacity) else {
                return
            }
            var err: NSError?
            let delivered = MutableBox(false)
            let result = conv.convert(to: out, error: &err) { _, status in
                if delivered.value { status.pointee = .noDataNow; return nil }
                delivered.value = true
                status.pointee = .haveData
                return buffer
            }
            if let err {
                log.error("Format conversion failed: \(err.localizedDescription)")
                return
            }
            if result == .error { return }
            targetBuffer = out
        } else {
            targetBuffer = buffer
        }

        // Step 2: feed samples into the ring buffer.
        guard let channelData = targetBuffer.floatChannelData else { return }
        let samples = channelData[0]
        ring.write(samples, count: Int(targetBuffer.frameLength))

        // Step 3: drain full 20 ms frames and encode.
        let frameSize = Int(AudioFormats.frameSize)
        let frameBuffer = AVAudioPCMBuffer(pcmFormat: AudioFormats.pcm, frameCapacity: AudioFormats.frameSize)!
        frameBuffer.frameLength = AudioFormats.frameSize

        while ring.count >= frameSize {
            guard let dest = frameBuffer.floatChannelData?[0] else { break }
            _ = ring.read(into: dest, count: frameSize)
            do {
                let packet = try encoder.encode(frameBuffer)
                onFrame?(packet)
            } catch {
                log.error("Opus encode failed: \(String(describing: error))")
            }
        }
    }
}
