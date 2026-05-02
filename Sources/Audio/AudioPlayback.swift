import AVFoundation
import os

/// Schedules decoded Opus frames for playback through the device speaker/earpiece/BT.
///
/// Each call to `play(opusFrame:)` decodes and immediately schedules a PCM buffer
/// on an AVAudioPlayerNode. The node plays buffers sequentially, smoothing over
/// bursts as long as we stay ahead of the playback pointer.
final class AudioPlayback {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let decoder: OpusDecoder
    private let log = Logger(subsystem: "com.klick.walkietalkie", category: "AudioPlayback")

    init() throws {
        self.decoder = try OpusDecoder()
    }

    func start() throws {
        try AudioSessionManager.shared.configureForPTT()
        try AudioSessionManager.shared.activate()

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: AudioFormats.pcm)
        engine.prepare()
        try engine.start()
        player.play()
        log.info("Playback started")
    }

    func stop() {
        player.stop()
        engine.stop()
    }

    func play(opusFrame: Data) {
        do {
            let pcm = try decoder.decode(opusFrame)
            player.scheduleBuffer(pcm, completionHandler: nil)
        } catch {
            log.error("Opus decode failed: \(String(describing: error))")
        }
    }
}
