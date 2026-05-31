import Foundation
import os

/// End-to-end audio pipeline: mic → Opus encode → Opus decode → speaker.
///
/// For M1 (no network) we wire capture output directly into playback as a
/// "loopback" so we can hear our own voice roundtripped through the codec,
/// confirming the audio layer works before we add UDP.
@MainActor
final class AudioPipeline: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?

    /// When true (M1 default), encoded frames are decoded locally and played back.
    /// When false, `onOutgoingFrame` is invoked instead — that hook is how later
    /// milestones (M2+) will feed frames into the UDP transport.
    var loopback = true

    /// Downstream hook for outgoing Opus frames. Set this in M2+ to send over UDP.
    var onOutgoingFrame: ((Data) -> Void)?

    private(set) var capture: AudioCapture?
    private var playback: AudioPlayback?
    private let log = Logger(subsystem: "world.madhans.klick", category: "AudioPipeline")

    func start() async {
        guard !isRunning else { return }
        errorMessage = nil
        let granted = await AudioSessionManager.shared.requestMicrophonePermission()
        guard granted else {
            errorMessage = "Microphone permission denied"
            return
        }
        do {
            let capture = try AudioCapture()
            let playback = try AudioPlayback()
            try playback.start()
            capture.onFrame = { [weak self] packet in
                guard let self else { return }
                // Only process frames when there's somewhere to send them.
                // Dropping idle frames prevents voice-processing artifacts
                // (distortion noise) from leaking to the output when the user
                // isn't transmitting.
                guard self.loopback || self.onOutgoingFrame != nil else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.loopback {
                        self.playback?.play(opusFrame: packet)
                    }
                    self.onOutgoingFrame?(packet)
                }
            }
            try capture.start()
            self.capture = capture
            self.playback = playback
            isRunning = true
            log.info("Pipeline running, loopback=\(self.loopback, privacy: .public)")
        } catch {
            errorMessage = "Failed to start: \(error.localizedDescription)"
            stop()
        }
    }

    func stop() {
        capture?.stop()
        playback?.stop()
        capture = nil
        playback = nil
        isRunning = false
    }

    /// Inject an incoming frame from the network (used in M2+).
    func receive(opusFrame: Data) {
        playback?.play(opusFrame: opusFrame)
    }
}
