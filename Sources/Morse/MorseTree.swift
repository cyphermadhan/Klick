import Foundation
import SwiftUI

/// Visual classification of a Morse tree node.
/// Matches the keychain reference: shape is determined by the most recent
/// step taken to reach the node.
enum MorseNodeShape: Equatable, Sendable {
    /// The root — no dit/dah input yet. Rendered as the antenna glyph.
    case root
    /// Arrived via a dah (−). Rendered as a square.
    case square
    /// Arrived via a dit (·). Rendered as a circle.
    case circle
}

/// State machine for the user's live Morse traversal.
///
/// Fed one `MorseElement` at a time from the UI (KEY-mode dit/dah buttons
/// or TAP-mode press-duration detection). `commit()` is called on gap
/// timeout to finalize the current letter; `addWordGap()` on a longer
/// gap to insert a space.
///
/// The view layer observes `currentPath` to highlight the active node in
/// the on-screen tree, `buffer` to show the composed message, and
/// `isOffTree` to indicate that the user keyed past the defined alphabet.
///
/// Main-actor bound because it feeds the UI directly through
/// `@Published` properties.
@MainActor
final class MorseTree: ObservableObject {
    /// Dit/dah sequence keyed since the last commit. Empty = at root.
    @Published private(set) var currentPath: [MorseElement] = []
    /// The composed message so far (what will go into the outbound packet).
    @Published var buffer: String = ""
    /// True once traversal has gone past the deepest defined character
    /// (punctuation tops out at 6 elements). `commit()` emits nothing
    /// while this is set.
    @Published private(set) var isOffTree = false

    /// Max depth corresponds to the longest defined sequence — 6 elements
    /// covers all ITU punctuation. Steps past this count trip `isOffTree`
    /// rather than growing the path unboundedly.
    private static let maxDepth = 6

    /// Character at the current node, if one is defined. Used by the view
    /// to show "you're on letter X" in the live readout above the tree.
    var currentLetter: Character? {
        guard !isOffTree else { return nil }
        return MorseCode.decode(currentPath)
    }

    /// Shape convention from the keychain photo: last step was dah → square,
    /// last step was dit → circle, no steps yet → root.
    var currentShape: MorseNodeShape {
        guard let last = currentPath.last else { return .root }
        return last == .dah ? .square : .circle
    }

    // MARK: - Input

    /// Walk one step down the tree. No-op once `isOffTree` is true —
    /// the user needs to commit or clear before more keying takes effect.
    func step(_ element: MorseElement) {
        if currentPath.count >= Self.maxDepth {
            isOffTree = true
            return
        }
        currentPath.append(element)
    }

    /// Finalize the current path: if it lands on a defined letter, that
    /// letter is appended to `buffer`. Undefined sequences are discarded
    /// silently so a mis-keyed run doesn't dump junk into the message.
    /// Always resets to root.
    func commit() {
        defer {
            currentPath.removeAll()
            isOffTree = false
        }
        guard !isOffTree, !currentPath.isEmpty else { return }
        if let char = MorseCode.decode(currentPath) {
            buffer.append(char)
        }
    }

    /// Insert a word boundary. Any pending letter is committed first so
    /// "HELLO WORLD" keys correctly when the user lets timeout happen on
    /// "O" and then presses the SPACE control.
    func addWordGap() {
        if !currentPath.isEmpty { commit() }
        // Avoid double-spaces and leading space.
        if !buffer.isEmpty, buffer.last != " " {
            buffer.append(" ")
        }
    }

    /// Undo the last dit/dah in the current path. Used by a backspace
    /// control while the user is mid-letter.
    func undoStep() {
        guard !currentPath.isEmpty else { return }
        currentPath.removeLast()
        isOffTree = false
    }

    /// Remove the last character from the committed buffer. Used by the
    /// same backspace control when `currentPath` is empty.
    func deleteLastCharacter() {
        guard !buffer.isEmpty else { return }
        buffer.removeLast()
    }

    /// Reset everything — both the in-flight path and the buffer.
    /// Called after a successful TX or on "CLEAR" button press.
    func clear() {
        currentPath.removeAll()
        buffer.removeAll()
        isOffTree = false
    }
}
