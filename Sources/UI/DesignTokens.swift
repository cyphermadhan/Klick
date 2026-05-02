import SwiftUI

/// Visual language for the app — tuned to feel like a cross between a
/// hardware sampler (Akai MPC) and a lab terminal readout:
///
/// * Pure black background
/// * SF Mono across the board with aggressive letter-spacing on caps
/// * Pixel-square status bars instead of rounded progress views
/// * One red accent for transmit / active states, one cyan for info
///
/// All colors and fonts funnel through here so the entire surface can
/// be retuned from a single file.
enum DT {
    // MARK: - Colors

    /// Background. Pure black — not UIColor.systemBackground.
    static let bg = Color.black
    /// Subtle panel fill used inside tiles and frames.
    static let panel = Color(white: 0.07)
    /// Hairline borders on terminal frames.
    static let border = Color(white: 0.18)
    /// Primary body text.
    static let text = Color(white: 0.92)
    /// Secondary / explainer text (the MPC "DISPLAY BPM" subtitle).
    static let textDim = Color(white: 0.52)
    /// Tertiary / inactive pixel squares.
    static let textFaint = Color(white: 0.22)

    /// MPC red — active / transmitting / alert.
    static let tx = Color(red: 0.92, green: 0.24, blue: 0.22)
    /// Deep red for pressed states.
    static let txDeep = Color(red: 0.76, green: 0.16, blue: 0.15)
    /// Stereo-blue / cyan — secondary status and data.
    static let info = Color(red: 0.22, green: 0.66, blue: 0.89)
    /// Paired-state green.
    static let ok = Color(red: 0.35, green: 0.82, blue: 0.45)
    /// Warn amber (unpaired).
    static let warn = Color(red: 0.95, green: 0.62, blue: 0.20)
    /// System-magenta (MPC "SYSTEM" pill).
    static let sys = Color(red: 0.92, green: 0.45, blue: 0.78)

    // MARK: - Fonts

    static let headerTracking: CGFloat = 2.0
    static let labelTracking: CGFloat = 1.4

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// The tiny explainer text under a label — "LIT WHEN SAMPLING" style.
    static let caption = mono(9, weight: .medium)
    /// Small readout labels — dial numbers, unit markers.
    static let readout = mono(11, weight: .regular)
    /// Bold all-caps label, e.g. "PEERS", "TRANSMIT".
    static let label = mono(13, weight: .bold)
    /// Large readouts — packet counts, the "38.4°" style numbers.
    static let number = mono(16, weight: .semibold)
    /// Display-size for the single hero metric (e.g. "TRANSMIT").
    static let display = mono(24, weight: .bold)

    // MARK: - Spacing

    static let rowHeight: CGFloat = 28
    static let tileCorner: CGFloat = 2   // Intentionally nearly-square. No rounded friendliness.
    static let framePad: CGFloat = 12
}

// MARK: - Text helpers

extension Text {
    /// "ALL CAPS" + tracking + mono. The standard walkie label treatment.
    func walkieLabel(_ size: CGFloat = 13, weight: Font.Weight = .bold, tracking: CGFloat = DT.labelTracking) -> Text {
        self.font(DT.mono(size, weight: weight))
            .tracking(tracking)
    }

    func walkieCaption() -> Text {
        self.font(DT.caption).tracking(DT.labelTracking)
    }
}
