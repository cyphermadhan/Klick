@preconcurrency import AVFoundation
import os

/// Synthesizes the two classic walkie-talkie UI sounds and plays them
/// locally when the PTT button is pressed and released:
///
///   • press  — a ~60 ms filtered-noise burst ("kkt" relay click)
///   • release — a ~160 ms 1 kHz "roger beep" with fast attack and release
///
/// Both buffers are generated once at init and scheduled on a dedicated
/// `AVAudioPlayerNode`, so these click/beeps mix *on top of* incoming
/// audio without interfering with the received-audio scheduling queue.
///
/// The synth engine shares the app's AVAudioSession, which the PTT
/// pipeline activates on start. Call `start()` when the session is live
/// and `stop()` when it tears down.
@MainActor
final class WalkieSoundSynth {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private let pressBuffer: AVAudioPCMBuffer
    private let releaseBuffer: AVAudioPCMBuffer
    private let log = Logger(subsystem: "com.klick.walkietalkie", category: "WalkieSoundSynth")

    init() {
        // 44.1 kHz mono Float32 — doesn't need to match the Opus pipeline's
        // 48 kHz format; the engine's mixer upsamples to the output as needed.
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1) else {
            fatalError("Failed to allocate synth audio format")
        }
        self.format = fmt
        self.pressBuffer = Self.makePressBuffer(format: fmt)
        self.releaseBuffer = Self.makeReleaseBuffer(format: fmt)
    }

    func start() {
        guard !engine.isRunning else { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do {
            try engine.start()
            player.play()
        } catch {
            log.error("Synth engine start failed: \(String(describing: error))")
        }
    }

    func stop() {
        player.stop()
        engine.stop()
    }

    func playPress() {
        scheduleOneShot(pressBuffer)
    }

    func playRelease() {
        scheduleOneShot(releaseBuffer)
    }

    private func scheduleOneShot(_ buffer: AVAudioPCMBuffer) {
        guard engine.isRunning else { return }
        // Use `.interrupts` so rapid press/release taps don't queue up and
        // play out of sync with the user's actual button state.
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
    }

    // MARK: - Buffer generators

    /// The key-up click: ~60 ms of white noise with a steep decay envelope,
    /// lightly low-passed (via simple one-pole IIR) so it sounds like a
    /// mechanical relay snap rather than harsh hiss.
    private static func makePressBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer {
        let sr = Float(format.sampleRate)
        let duration: Float = 0.060
        let frameCount = AVAudioFrameCount(sr * duration)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buf.frameLength = frameCount
        let samples = buf.floatChannelData![0]

        // One-pole low-pass state; cutoff around 3 kHz.
        let alpha: Float = 0.45
        var last: Float = 0

        let total = Int(frameCount)
        for i in 0..<total {
            let raw = Float.random(in: -1...1)
            // Low-pass filter: y[n] = α*x[n] + (1-α)*y[n-1]
            let filtered = alpha * raw + (1 - alpha) * last
            last = filtered
            // Exponential amplitude decay for a "click" shape.
            let t = Float(i) / Float(total)
            let env = exp(-5 * t)
            samples[i] = filtered * env * 0.35
        }
        return buf
    }

    /// The key-down "roger beep": ~160 ms of a 1 kHz sine with 5 ms attack
    /// and 40 ms release to avoid audible pops at the edges.
    private static func makeReleaseBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer {
        let sr = Float(format.sampleRate)
        let duration: Float = 0.16
        let freq: Float = 1_000
        let frameCount = AVAudioFrameCount(sr * duration)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buf.frameLength = frameCount
        let samples = buf.floatChannelData![0]

        let total = Int(frameCount)
        let attack = Int(sr * 0.005)
        let release = Int(sr * 0.040)
        let peak: Float = 0.28

        for i in 0..<total {
            var env: Float = peak
            if i < attack {
                env *= Float(i) / Float(attack)
            } else if i > total - release {
                env *= Float(total - i) / Float(release)
            }
            samples[i] = sin(2 * .pi * freq * Float(i) / sr) * env
        }
        return buf
    }
}
