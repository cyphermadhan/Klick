import AudioToolbox
import Foundation

/// Short click tones played when the user presses and releases the PTT button.
/// Uses AudioServicesPlaySystemSound so they don't interfere with the main
/// AVAudioEngine pipeline.
enum PTTSoundEffects {
    /// System sound IDs chosen subjectively for "crisp walkie-talkie" feel.
    /// 1104 = "Tock" (keyboard tap) — short and dry.
    /// 1105 = similar but slightly higher pitch.
    private static let beginID: SystemSoundID = 1104
    private static let endID: SystemSoundID = 1105

    static func playBegin() {
        AudioServicesPlaySystemSound(beginID)
    }

    static func playEnd() {
        AudioServicesPlaySystemSound(endID)
    }
}
