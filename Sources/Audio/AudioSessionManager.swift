import AVFoundation

/// Manages the shared AVAudioSession for push-to-talk usage.
///
/// `.playAndRecord` + `.voiceChat` gives us echo cancellation, voice processing,
/// and the ear-piece/speaker/Bluetooth routing hierarchy we want for PTT.
final class AudioSessionManager: Sendable {
    static let shared = AudioSessionManager()
    private init() {}

    func configureForPTT() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]
        )
        try session.setPreferredSampleRate(AudioFormats.sampleRate)
        try session.setPreferredIOBufferDuration(0.020) // 20 ms
    }

    func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setActive(true, options: [])
        // `.voiceChat` mode defaults to the earpiece (phone-call style)
        // even with `.defaultToSpeaker` set. Force the loudspeaker for
        // walkie-talkie UX — the override still defers to wired headphones
        // and Bluetooth headsets automatically when those are connected.
        try session.overrideOutputAudioPort(.speaker)
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
}
