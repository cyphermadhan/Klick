import Foundation

/// Preset Morse-code speeds exposed to the user.
///
/// Behind the scenes everything (tone synth, flashlight beacon, TAP
/// threshold, receiver replay) is parameterized on WPM (words per
/// minute, PARIS standard). The UI doesn't ask the user to know that —
/// a three-option dropdown Slow / Medium / Fast covers the realistic
/// range for a casual messaging app without surfacing WPM at all.
///
/// If we ever need an "expert mode" that lets the user pick any WPM,
/// we can revisit — but for now clarity wins over precision.
enum MorseSpeed: Int, CaseIterable, Sendable, Codable {
    /// Beginner pace — individual dits and dahs are clearly audible.
    case slow   = 8
    /// Conversational — Klick's default, matches the historical
    /// amateur-radio license floor.
    case medium = 12
    /// "Head copy" pace for someone who's been practicing. Near the
    /// upper end of what a casual listener can follow by ear.
    case fast   = 20

    /// Short all-caps label for the dropdown UI.
    var label: String {
        switch self {
        case .slow:   return "SLOW"
        case .medium: return "MEDIUM"
        case .fast:   return "FAST"
        }
    }

    /// WPM integer used by the rest of the Morse stack. Named for the
    /// symmetry with `MorseTone`, etc. — they all take a `wpm: Int`.
    var wpm: Int { rawValue }
}
