import XCTest
@testable import KlickKlick

final class MorseCodeTests: XCTestCase {

    // MARK: - Alphabet coverage

    func testAlphabetCoversAllLettersAndDigits() {
        for char in "ABCDEFGHIJKLMNOPQRSTUVWXYZ" {
            XCTAssertNotNil(MorseCode.alphabet[char], "Missing \(char)")
        }
        for char in "0123456789" {
            XCTAssertNotNil(MorseCode.alphabet[char], "Missing digit \(char)")
        }
    }

    func testRoundtripForAllDefinedCharacters() {
        // encode→decode for every defined char should return the original.
        for (char, elements) in MorseCode.alphabet {
            XCTAssertEqual(
                MorseCode.decode(elements),
                char,
                "Roundtrip failed for \(char)"
            )
        }
    }

    // MARK: - Specific well-known sequences

    func testSosEncoding() {
        // "SOS" is the classic three-dit / three-dah / three-dit.
        let frames = MorseCode.encode("SOS")
        // S = ··· , letterGap, O = −−− , letterGap, S = ···
        let expected: [MorseFrame] = [
            .dit, .dit, .dit,
            .letterGap,
            .dah, .dah, .dah,
            .letterGap,
            .dit, .dit, .dit
        ]
        XCTAssertEqual(frames, expected)
    }

    func testEncodesWordGapForSpaces() {
        let frames = MorseCode.encode("E T")
        // E, wordGap, T
        XCTAssertEqual(frames, [.dit, .wordGap, .dah])
    }

    func testEncodeIsCaseInsensitive() {
        XCTAssertEqual(MorseCode.encode("hi"), MorseCode.encode("HI"))
    }

    func testUndefinedCharactersAreDropped() {
        // `#` is not in our alphabet — it should be skipped silently and
        // the rest of the string should encode as if `#` weren't there.
        let frames = MorseCode.encode("A#B")
        let expected = MorseCode.encode("AB")
        XCTAssertEqual(frames, expected)
    }

    // MARK: - Decode edge cases

    func testDecodeUndefinedSequenceReturnsNil() {
        // Eight dits — longer than any defined sequence, never assigned.
        XCTAssertNil(MorseCode.decode([.dit, .dit, .dit, .dit, .dit, .dit, .dit, .dit]))
    }

    func testDecodeEmptyReturnsNil() {
        XCTAssertNil(MorseCode.decode([]))
    }
}
