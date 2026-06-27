@preconcurrency import AVFoundation
import os

/// Manages the shared AVAudioSession for push-to-talk usage.
///
/// Category: `.playAndRecord` (we need both).
/// Mode:     `.default`.
///
/// We deliberately avoid `.voiceChat` and `.videoChat` modes. Those modes
/// attach the session to the *ring/call volume* channel — which is why
/// users report walkie audio is noticeably quieter than Spotify even with
/// the media volume maxed. `.default` mode uses the *media volume*, so
/// playback is at the same level as any other audio app.
///
/// We still want echo cancellation / noise suppression — otherwise the
/// speaker output gets picked up by the mic and transmitted back to the
/// sender. Apple's voice-processing IO is enabled directly on the capture
/// engine's input node (see `AudioCapture`), independent of the session
/// mode. That keeps the volume channel correct while still processing
/// the mic signal.
///
/// A `routeChangeNotification` observer re-asserts the speaker override
/// whenever iOS changes audio routing (Bluetooth disconnect, interruption
/// end, etc.), so the loudspeaker stays selected unless headphones or a
/// BT headset are actually connected.
final class AudioSessionManager: @unchecked Sendable {
    static let shared = AudioSessionManager()
    private let log = Logger(subsystem: "world.madhans.klick", category: "AudioSession")
    private var routeObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?

    private init() {
        installRouteObserver()
        installInterruptionObserver()
    }

    func configureForPTT() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]
        )
        try session.setPreferredSampleRate(AudioFormats.sampleRate)
        try session.setPreferredIOBufferDuration(0.020) // 20 ms
    }

    func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setActive(true, options: [])
        applySpeakerOverride()
    }

    func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { cont in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { cont.resume(returning: $0) }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { cont.resume(returning: $0) }
            }
        }
    }

    // MARK: - Speaker routing

    /// Force the loudspeaker. Wired headphones and Bluetooth headsets are
    /// higher-priority routes and keep working — iOS defers the override
    /// to them automatically.
    private func applySpeakerOverride() {
        do {
            try AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
        } catch {
            log.error("Speaker override failed: \(String(describing: error))")
        }
    }

    /// Re-activate the audio session after an interruption ends (incoming
    /// phone call, Siri, alarm). Without this, the AVAudioEngine stays
    /// paused after the interrupting event releases focus — symptom: PTT
    /// "works" but no sound plays until the user toggles LINK off/on.
    private func installInterruptionObserver() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let info = note.userInfo,
                  let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

            switch type {
            case .began:
                self.log.info("Audio interruption began")
            case .ended:
                // Re-activate so subsequent playback resumes immediately.
                // Caller (AudioPipeline) is responsible for re-starting
                // its engines on the next start() — for already-running
                // engines, AVAudioEngine resumes automatically once the
                // session is active again.
                do {
                    try AVAudioSession.sharedInstance().setActive(true, options: [])
                    self.applySpeakerOverride()
                    self.log.info("Audio session re-activated after interruption")
                } catch {
                    self.log.error("Re-activate failed: \(String(describing: error))")
                }
            @unknown default:
                break
            }
        }
    }

    /// Re-apply speaker routing whenever iOS changes the audio route.
    /// `.videoChat` mode is well-behaved, but things like a Bluetooth
    /// headset disconnecting, an incoming call finishing, or Siri
    /// interrupting and handing control back can all leave the route
    /// pointing at the earpiece. Re-asserting is cheap and reliable.
    private func installRouteObserver() {
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            // Only re-apply if the session is currently configured — i.e.
            // we're in PTT mode. Otherwise we might fight with other apps.
            let session = AVAudioSession.sharedInstance()
            guard session.category == .playAndRecord else { return }
            self.log.info("Route change: \(String(describing: note.userInfo?[AVAudioSessionRouteChangeReasonKey]), privacy: .public)")
            self.applySpeakerOverride()
        }
    }
}
