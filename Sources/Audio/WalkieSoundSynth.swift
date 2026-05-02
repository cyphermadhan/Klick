@preconcurrency import AVFoundation
import os

/// Plays the bundled walkie press/release sounds.
///
/// Uses `AVAudioPlayer` rather than a custom `AVAudioEngine` setup because
/// it handles MP3 decoding natively, manages its own playback lifecycle,
/// and respects the shared `AVAudioSession` the PTT pipeline configures —
/// no fragile engine wiring or buffer-format dance.
///
/// The two players are preloaded at init (via `prepareToPlay`) so taps
/// are instant.
@MainActor
final class WalkieSoundSynth {
    private var pressPlayer: AVAudioPlayer?
    private var releasePlayer: AVAudioPlayer?
    private let log = Logger(subsystem: "com.klick.walkietalkie", category: "WalkieSoundSynth")

    init() {
        pressPlayer = makePlayer(name: "walkie-press")
        releasePlayer = makePlayer(name: "walkie-release")

        if pressPlayer == nil {
            log.error("walkie-press audio asset missing from bundle")
        }
        if releasePlayer == nil {
            log.error("walkie-release audio asset missing from bundle")
        }
    }

    func start() {
        pressPlayer?.prepareToPlay()
        releasePlayer?.prepareToPlay()
    }

    func stop() {
        pressPlayer?.stop()
        releasePlayer?.stop()
    }

    func playPress() {
        restart(pressPlayer)
    }

    func playRelease() {
        restart(releasePlayer)
    }

    private func restart(_ player: AVAudioPlayer?) {
        guard let player else { return }
        // Rewind first so rapid press/release taps never miss because a
        // previous playback is still in-flight.
        player.currentTime = 0
        player.volume = 1.0
        player.play()
    }

    // MARK: - Loader

    /// Try common audio-asset extensions in order. First file that loads
    /// wins. Anything missing falls through to `nil` and that sound just
    /// becomes a silent no-op rather than a crash.
    private func makePlayer(name: String) -> AVAudioPlayer? {
        for ext in ["mp3", "m4a", "wav", "caf"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: ext) else { continue }
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.prepareToPlay()
                player.volume = 1.0
                return player
            } catch {
                log.error("Failed to load \(name).\(ext): \(String(describing: error))")
            }
        }
        return nil
    }
}
