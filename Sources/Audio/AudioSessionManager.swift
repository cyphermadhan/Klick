@preconcurrency import AVFoundation
import os

/// Manages the shared AVAudioSession for push-to-talk usage.
///
/// We use `.videoChat` mode rather than `.voiceChat` on purpose:
/// `.voiceChat` mimics a phone call and actively routes audio to the
/// earpiece (using the proximity sensor), silently overriding
/// `overrideOutputAudioPort(.speaker)`. `.videoChat` still gives us
/// Apple's voice-processing IO (echo cancellation, noise suppression)
/// but defaults to the loudspeaker for hands-free use — which is what
/// a walkie-talkie needs.
///
/// We also install a route-change observer that re-asserts the speaker
/// override whenever iOS changes audio routing (Bluetooth disconnect,
/// category reset, etc.), so the loudspeaker stays selected unless
/// the user plugs in headphones.
final class AudioSessionManager: @unchecked Sendable {
    static let shared = AudioSessionManager()
    private let log = Logger(subsystem: "com.klick.walkietalkie", category: "AudioSession")
    private var routeObserver: NSObjectProtocol?

    private init() {
        installRouteObserver()
    }

    func configureForPTT() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .videoChat,
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
