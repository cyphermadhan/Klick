import Foundation

/// State machine that turns a stream of on/off pulse durations into
/// Morse characters.
///
/// Callers (the flashlight decoder, the audio-tone decoder, or any future
/// sensor) feed two events:
///   - `signalDidGoOn(at:)`   when the sensed signal crosses low → high
///   - `signalDidGoOff(at:)`  when the signal crosses high → low
///
/// The demodulator computes pulse + gap durations in-flight, classifies
/// them against an adaptive dit-unit (shortest observed on-duration,
/// with a floor so one noise blip can't redefine the scale), and emits
/// decoded characters via `onCharacter`. Word gaps and end-of-message
/// silences are flushed lazily from `tick(at:)` — callers fire that
/// every 100 ms or so to keep the "it's been quiet for a while, commit
/// this letter" logic moving when no new transitions arrive.
///
/// Timing classification per ITU:
///   - dit  = 1 unit on
///   - dah  = 3 units on  (boundary: 2 units is the midpoint)
///   - intra-char gap = 1 unit off (implicit, between dits/dahs)
///   - letter gap     = 3 units off (boundary: 2 units commits)
///   - word gap       = 7 units off (boundary: 5 units emits a space)
///
/// The decoder doesn't know the sender's WPM in advance. It seeds the
/// unit with a default (100 ms = 12 WPM) and refines it every time it
/// sees a shorter on-duration — common case: the sender keys an `E`
/// or `I` early and that gives us the unit for the rest of the message.
@MainActor
final class MorseDemodulator {
    /// Called whenever a letter commits. `' '` indicates a word boundary.
    /// Runs on the main actor — safe to touch UI state directly.
    var onCharacter: ((Character) -> Void)?

    /// Current estimate of the dit-unit in ms. Adapts downward as
    /// shorter pulses are observed; never goes below the floor.
    ///
    /// Seeded generously (300 ms ≈ 4 WPM) so a slow keyer's first pulse
    /// isn't misclassified as a dah. Fast senders cause this to narrow
    /// on the first dit they send. If we seeded low (e.g. 100 ms),
    /// every slow-speed pulse ≥ 200 ms would read as a dah — turning
    /// SOS into TTT.
    private(set) var ditUnitMs: Double = 300.0
    private static let minDitUnitMs: Double = 30.0   // 40 WPM ceiling
    private static let maxDitUnitMs: Double = 500.0  // ~2 WPM floor

    /// In-flight dits/dahs accumulated since the last letter-gap.
    private var currentLetter: [MorseElement] = []
    /// Most recent edge timestamps in absolute ms. `nil` means "haven't
    /// seen that kind of edge yet in this session".
    private var lastOnAt: Double?
    private var lastOffAt: Double?
    /// True while the signal is currently high. Used so `tick` knows
    /// whether a quiet window should commit the letter (off-state long
    /// enough = letter boundary) or is mid-pulse (still on, ignore).
    private var signalIsOn: Bool = false
    /// Set after we commit a letter so the NEXT long-enough silence
    /// emits a space — prevents emitting a space on the very first gap
    /// after nothing has been decoded yet.
    private var letterCommittedSinceLastSpace: Bool = false

    // MARK: - Input (signal edges)

    /// Report a low-to-high transition. `nowMs` is any monotonic ms value
    /// (e.g. `Date().timeIntervalSince1970 * 1000`) — only diffs matter.
    func signalDidGoOn(at nowMs: Double) {
        // Gap that just ended — classify it against the unit.
        if let off = lastOffAt, letterCommittedSinceLastSpace || !currentLetter.isEmpty {
            let gapMs = nowMs - off
            classifyGap(gapMs)
        }
        lastOnAt = nowMs
        signalIsOn = true
    }

    /// Report a high-to-low transition.
    func signalDidGoOff(at nowMs: Double) {
        guard let on = lastOnAt else {
            // Off without prior on — ignore (we booted in the middle of a
            // signal, or the sensor caught noise).
            return
        }
        let onMs = nowMs - on
        classifyPulse(onMs)
        lastOffAt = nowMs
        signalIsOn = false
    }

    /// Called periodically (e.g. every 100 ms). If we're currently idle
    /// and the silence has crossed the letter- or word-gap threshold,
    /// commit what's buffered. Without this, an operator who stops
    /// keying mid-message would see the last letter stuck in-flight.
    func tick(at nowMs: Double) {
        guard !signalIsOn, let off = lastOffAt else { return }
        let gapMs = nowMs - off
        classifyGap(gapMs)
    }

    /// Reset all state — used when the decoder view reopens or the user
    /// explicitly clears the RX buffer.
    func reset() {
        currentLetter.removeAll()
        lastOnAt = nil
        lastOffAt = nil
        signalIsOn = false
        letterCommittedSinceLastSpace = false
        ditUnitMs = 300.0
    }

    // MARK: - Private classification

    private func classifyPulse(_ onMs: Double) {
        // Adapt the unit downward when we see a shorter on-duration
        // (but only if it's plausibly a dit, not random noise). We don't
        // adapt upward — a long pulse is a dah by construction.
        if onMs >= Self.minDitUnitMs && onMs < ditUnitMs {
            ditUnitMs = onMs
        }
        // 2-unit boundary: anything ≥ 2 units reads as a dah.
        let element: MorseElement = onMs >= ditUnitMs * 2 ? .dah : .dit
        guard currentLetter.count < 6 else { return } // off-tree, drop
        currentLetter.append(element)
    }

    private func classifyGap(_ gapMs: Double) {
        // Intra-character gap (≤ ~2 units): part of the current letter,
        // nothing to commit yet.
        if gapMs < ditUnitMs * 2 {
            return
        }
        // Letter-gap (≥ 2 units): commit current buffer as a character.
        if !currentLetter.isEmpty {
            if let char = MorseCode.decode(currentLetter) {
                onCharacter?(char)
                letterCommittedSinceLastSpace = true
            }
            currentLetter.removeAll()
            // Reset the off-mark so the same gap doesn't fire again on
            // the next tick — without this the "still quiet" check would
            // re-commit every 100 ms.
            lastOffAt = nil
        }
        // Word-gap (≥ ~5 units) — emit a space, but only once per quiet
        // stretch.
        if gapMs >= ditUnitMs * 5 && letterCommittedSinceLastSpace {
            onCharacter?(" ")
            letterCommittedSinceLastSpace = false
            lastOffAt = nil
        }
    }
}
