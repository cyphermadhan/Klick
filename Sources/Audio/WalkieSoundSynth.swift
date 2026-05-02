@preconcurrency import AVFoundation
import os

/// Plays the app's bundled walkie-talkie press/release sound files locally
/// whenever the user grabs or releases the PTT button. The mp3s are decoded
/// into PCM buffers at init time so button presses are instant — no disk
/// I/O or decode latency when the user actually taps.
///
/// A dedicated `AVAudioPlayerNode` sits alongside the received-audio node,
/// so these clicks mix *on top of* incoming voice rather than fighting
/// for the same schedule queue.
@MainActor
final class WalkieSoundSynth {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let pressBuffer: AVAudioPCMBuffer?
    private let releaseBuffer: AVAudioPCMBuffer?
    private let playbackFormat: AVAudioFormat
    private let log = Logger(subsystem: "com.klick.walkietalkie", category: "WalkieSoundSynth")

    init() {
        let press = Self.loadBuffer(name: "walkie-press")
        let release = Self.loadBuffer(name: "walkie-release")
        self.pressBuffer = press
        self.releaseBuffer = release

        // Connect using whichever buffer format is available; fall back to
        // a generic 44.1 kHz stereo format if both files failed to load
        // (in which case playback is silently a no-op).
        self.playbackFormat = press?.format
            ?? release?.format
            ?? AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    }

    func start() {
        guard !engine.isRunning else { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
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
        schedule(pressBuffer)
    }

    func playRelease() {
        schedule(releaseBuffer)
    }

    private func schedule(_ buffer: AVAudioPCMBuffer?) {
        guard engine.isRunning, let buffer else { return }
        // `.interrupts` — a new press/release cancels anything still playing
        // on this node so rapid tap-tap-tap stays in sync with button state.
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
    }

    // MARK: - Asset loader

    /// Reads a bundled audio file (any AVAudioFile-supported format) into a
    /// fully-populated PCM buffer. Returns nil on any failure — callers
    /// treat missing buffers as silent no-ops.
    private static func loadBuffer(name: String) -> AVAudioPCMBuffer? {
        // Try mp3 first, then wav as a fallback in case the asset format changes later.
        let candidates: [(String, String)] = [(name, "mp3"), (name, "wav"), (name, "m4a"), (name, "caf")]
        for (resource, ext) in candidates {
            if let url = Bundle.main.url(forResource: resource, withExtension: ext) {
                if let buffer = loadPCM(from: url) {
                    return buffer
                }
            }
        }
        return nil
    }

    private static func loadPCM(from url: URL) -> AVAudioPCMBuffer? {
        do {
            let file = try AVAudioFile(forReading: url)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
            ) else { return nil }
            try file.read(into: buffer)
            return buffer
        } catch {
            return nil
        }
    }
}
