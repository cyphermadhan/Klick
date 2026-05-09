import XCTest
@testable import KlickKlick

@MainActor
final class MorseDemodulatorTests: XCTestCase {

    /// Box a string so the `@Sendable`-style capture in `onCharacter`
    /// can append without tripping Swift concurrency rules.
    private final class Captured { var text = "" }

    private func makeDemod(capture: Captured) -> MorseDemodulator {
        let demod = MorseDemodulator()
        demod.onCharacter = { capture.text.append($0) }
        return demod
    }

    /// Drive the demodulator with alternating on/off events derived from
    /// a `[MorseFrame]` schedule. `unit` is the dit-unit we're simulating
    /// the *sender* used; the demodulator figures it out itself from
    /// the shortest pulse it sees.
    private func drive(_ demod: MorseDemodulator, frames: [MorseFrame], unit: Double) {
        var now: Double = 0
        // Start from an already-on signal at t=0 so the first gap
        // classification has `lastOffAt` populated after the first dit.
        for frame in frames {
            switch frame {
            case .dit:
                demod.signalDidGoOn(at: now)
                now += unit
                demod.signalDidGoOff(at: now)
                now += unit // intra-character gap
            case .dah:
                demod.signalDidGoOn(at: now)
                now += unit * 3
                demod.signalDidGoOff(at: now)
                now += unit // intra-character gap
            case .letterGap:
                // Sender already added 1 unit of silence after the last
                // pulse. Letter gap is 3 units total → 2 more here.
                now += unit * 2
            case .wordGap:
                // Same logic: 1 unit already passed, need 7 total → 6 more.
                now += unit * 6
            }
        }
        // Final flush so the trailing letter/word commits.
        demod.tick(at: now + unit * 10)
    }

    // MARK: - Basic letter decoding

    func testDecodesSingleLetter() {
        let captured = Captured()
        let demod = makeDemod(capture: captured)
        drive(demod, frames: MorseCode.encode("A"), unit: 100)
        XCTAssertEqual(captured.text.trimmingCharacters(in: .whitespaces), "A")
    }

    func testDecodesSOS() {
        let captured = Captured()
        let demod = makeDemod(capture: captured)
        drive(demod, frames: MorseCode.encode("SOS"), unit: 100)
        XCTAssertEqual(captured.text.trimmingCharacters(in: .whitespaces), "SOS")
    }

    func testDecodesMultipleLetters() {
        let captured = Captured()
        let demod = makeDemod(capture: captured)
        drive(demod, frames: MorseCode.encode("HELLO"), unit: 100)
        XCTAssertEqual(captured.text.trimmingCharacters(in: .whitespaces), "HELLO")
    }

    // MARK: - Word boundaries

    func testEmitsSpaceOnWordGap() {
        let captured = Captured()
        let demod = makeDemod(capture: captured)
        drive(demod, frames: MorseCode.encode("HI BYE"), unit: 100)
        XCTAssertEqual(captured.text.trimmingCharacters(in: .whitespaces), "HI BYE")
    }

    // MARK: - Variable WPM

    func testDecodesAtSlowSpeed() {
        let captured = Captured()
        let demod = makeDemod(capture: captured)
        // 300 ms dit = 4 WPM, a slow learner. The demodulator should
        // adapt its ditUnitMs to the observed pulse length.
        drive(demod, frames: MorseCode.encode("SOS"), unit: 300)
        XCTAssertEqual(captured.text.trimmingCharacters(in: .whitespaces), "SOS")
    }

    func testDecodesAtFastSpeed() {
        let captured = Captured()
        let demod = makeDemod(capture: captured)
        // 50 ms dit = 24 WPM, on the fast side.
        drive(demod, frames: MorseCode.encode("SOS"), unit: 50)
        XCTAssertEqual(captured.text.trimmingCharacters(in: .whitespaces), "SOS")
    }

    // MARK: - Adaptive unit

    func testAdaptsDitUnitDownwardWhenShorterPulseSeen() {
        let captured = Captured()
        let demod = makeDemod(capture: captured)
        let initialUnit = demod.ditUnitMs

        // Key a single dit at 60 ms — demodulator should narrow its
        // unit estimate, letting later fast dahs be classified correctly.
        demod.signalDidGoOn(at: 0)
        demod.signalDidGoOff(at: 60)

        XCTAssertLessThan(demod.ditUnitMs, initialUnit)
        XCTAssertEqual(demod.ditUnitMs, 60, accuracy: 1)
    }

    // MARK: - Reset

    func testResetClearsInflightLetter() {
        let captured = Captured()
        let demod = makeDemod(capture: captured)
        // Half a letter (two dots — no commit yet).
        demod.signalDidGoOn(at: 0)
        demod.signalDidGoOff(at: 100)
        demod.signalDidGoOn(at: 200)
        demod.signalDidGoOff(at: 300)
        demod.reset()
        // After reset, even a generous tick should produce nothing.
        demod.tick(at: 10_000)
        XCTAssertEqual(captured.text, "")
    }
}
