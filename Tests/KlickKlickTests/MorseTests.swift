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

/// MorseTree interacts with @Published state, so hop to main actor.
@MainActor
final class MorseTreeTests: XCTestCase {

    func testRootStateIsEmpty() {
        let tree = MorseTree()
        XCTAssertTrue(tree.currentPath.isEmpty)
        XCTAssertEqual(tree.buffer, "")
        XCTAssertEqual(tree.currentShape, .root)
        XCTAssertNil(tree.currentLetter)
        XCTAssertFalse(tree.isOffTree)
    }

    func testSingleDitLandsOnE() {
        let tree = MorseTree()
        tree.step(.dit)
        XCTAssertEqual(tree.currentLetter, "E")
        XCTAssertEqual(tree.currentShape, .circle)
    }

    func testSingleDahLandsOnT() {
        let tree = MorseTree()
        tree.step(.dah)
        XCTAssertEqual(tree.currentLetter, "T")
        XCTAssertEqual(tree.currentShape, .square)
    }

    func testCommitAppendsLetterAndResets() {
        let tree = MorseTree()
        tree.step(.dit)
        tree.step(.dah)        // A
        tree.commit()
        XCTAssertEqual(tree.buffer, "A")
        XCTAssertTrue(tree.currentPath.isEmpty)
    }

    func testMultipleLettersBuildBuffer() {
        let tree = MorseTree()
        // S (···)
        tree.step(.dit); tree.step(.dit); tree.step(.dit)
        tree.commit()
        // O (−−−)
        tree.step(.dah); tree.step(.dah); tree.step(.dah)
        tree.commit()
        // S (···)
        tree.step(.dit); tree.step(.dit); tree.step(.dit)
        tree.commit()
        XCTAssertEqual(tree.buffer, "SOS")
    }

    func testWordGapInsertsSpace() {
        let tree = MorseTree()
        tree.step(.dit)
        tree.addWordGap()          // commits E and adds space
        tree.step(.dah)
        tree.commit()
        XCTAssertEqual(tree.buffer, "E T")
    }

    func testWordGapDoesNotDoubleSpace() {
        let tree = MorseTree()
        tree.buffer = "HI "
        tree.addWordGap()
        XCTAssertEqual(tree.buffer, "HI ")
    }

    func testUndefinedSequenceCommitsNothing() {
        let tree = MorseTree()
        // 8 dits — not a valid letter.
        for _ in 0..<6 { tree.step(.dit) }
        tree.commit()
        XCTAssertEqual(tree.buffer, "")
    }

    func testOverDeepStepTripsOffTreeFlag() {
        let tree = MorseTree()
        for _ in 0..<6 { tree.step(.dit) }
        XCTAssertFalse(tree.isOffTree, "6 steps should be allowed (max depth)")
        tree.step(.dit)  // 7th step — over max
        XCTAssertTrue(tree.isOffTree)
    }

    func testUndoStepRemovesLastElement() {
        let tree = MorseTree()
        tree.step(.dit)
        tree.step(.dah)
        tree.undoStep()
        XCTAssertEqual(tree.currentPath, [.dit])
        XCTAssertEqual(tree.currentLetter, "E")
    }

    func testUndoStepClearsOffTree() {
        let tree = MorseTree()
        for _ in 0..<7 { tree.step(.dit) }  // trips off-tree
        XCTAssertTrue(tree.isOffTree)
        tree.undoStep()
        XCTAssertFalse(tree.isOffTree)
    }

    func testDeleteLastCharacter() {
        let tree = MorseTree()
        tree.buffer = "SOS"
        tree.deleteLastCharacter()
        XCTAssertEqual(tree.buffer, "SO")
        tree.deleteLastCharacter()
        tree.deleteLastCharacter()
        tree.deleteLastCharacter()  // empty-safe
        XCTAssertEqual(tree.buffer, "")
    }

    func testClearResetsEverything() {
        let tree = MorseTree()
        tree.buffer = "HELLO"
        tree.step(.dit); tree.step(.dah)
        tree.clear()
        XCTAssertTrue(tree.currentPath.isEmpty)
        XCTAssertEqual(tree.buffer, "")
        XCTAssertFalse(tree.isOffTree)
    }
}
