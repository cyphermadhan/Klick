import Foundation

/// One elemental Morse pulse. The tree state machine consumes these one
/// at a time; the playback synth emits them with appropriate timing.
enum MorseElement: Equatable, Hashable, Sendable {
    /// Short pulse, one unit long. Visually "·".
    case dit
    /// Long pulse, three units long. Visually "−".
    case dah
}

/// A timed event in a Morse stream — pulses plus the gaps between them.
/// Used by `encode(_ text:)` to produce a schedule the tone synth can play,
/// and by receivers streaming dit/dah events from the air (future).
///
/// Durations per ITU (in "dit units"):
///   dit        = 1
///   dah        = 3
///   intra-char = 1   (implicit between dits/dahs within a letter)
///   letterGap  = 3
///   wordGap    = 7
enum MorseFrame: Equatable, Sendable {
    case dit
    case dah
    case letterGap
    case wordGap
}

enum MorseCode {

    // MARK: - Alphabet

    /// International Morse alphabet: letters A–Z, digits 0–9, and common
    /// punctuation. Lookup is case-insensitive (encode uppercases first).
    /// Extended characters (Ä, Ö, Ü, CH) omitted for the first cut — can be
    /// added later without wire-format changes.
    static let alphabet: [Character: [MorseElement]] = [
        "A": [.dit, .dah],
        "B": [.dah, .dit, .dit, .dit],
        "C": [.dah, .dit, .dah, .dit],
        "D": [.dah, .dit, .dit],
        "E": [.dit],
        "F": [.dit, .dit, .dah, .dit],
        "G": [.dah, .dah, .dit],
        "H": [.dit, .dit, .dit, .dit],
        "I": [.dit, .dit],
        "J": [.dit, .dah, .dah, .dah],
        "K": [.dah, .dit, .dah],
        "L": [.dit, .dah, .dit, .dit],
        "M": [.dah, .dah],
        "N": [.dah, .dit],
        "O": [.dah, .dah, .dah],
        "P": [.dit, .dah, .dah, .dit],
        "Q": [.dah, .dah, .dit, .dah],
        "R": [.dit, .dah, .dit],
        "S": [.dit, .dit, .dit],
        "T": [.dah],
        "U": [.dit, .dit, .dah],
        "V": [.dit, .dit, .dit, .dah],
        "W": [.dit, .dah, .dah],
        "X": [.dah, .dit, .dit, .dah],
        "Y": [.dah, .dit, .dah, .dah],
        "Z": [.dah, .dah, .dit, .dit],

        "0": [.dah, .dah, .dah, .dah, .dah],
        "1": [.dit, .dah, .dah, .dah, .dah],
        "2": [.dit, .dit, .dah, .dah, .dah],
        "3": [.dit, .dit, .dit, .dah, .dah],
        "4": [.dit, .dit, .dit, .dit, .dah],
        "5": [.dit, .dit, .dit, .dit, .dit],
        "6": [.dah, .dit, .dit, .dit, .dit],
        "7": [.dah, .dah, .dit, .dit, .dit],
        "8": [.dah, .dah, .dah, .dit, .dit],
        "9": [.dah, .dah, .dah, .dah, .dit],

        ".": [.dit, .dah, .dit, .dah, .dit, .dah],
        ",": [.dah, .dah, .dit, .dit, .dah, .dah],
        "?": [.dit, .dit, .dah, .dah, .dit, .dit],
        "'": [.dit, .dah, .dah, .dah, .dah, .dit],
        "!": [.dah, .dit, .dah, .dit, .dah, .dah],
        "/": [.dah, .dit, .dit, .dah, .dit],
        "(": [.dah, .dit, .dah, .dah, .dit],
        ")": [.dah, .dit, .dah, .dah, .dit, .dah],
        "&": [.dit, .dah, .dit, .dit, .dit],
        ":": [.dah, .dah, .dah, .dit, .dit, .dit],
        ";": [.dah, .dit, .dah, .dit, .dah, .dit],
        "=": [.dah, .dit, .dit, .dit, .dah],
        "+": [.dit, .dah, .dit, .dah, .dit],
        "-": [.dah, .dit, .dit, .dit, .dit, .dah],
        "_": [.dit, .dit, .dah, .dah, .dit, .dah],
        "\"": [.dit, .dah, .dit, .dit, .dah, .dit],
        "@": [.dit, .dah, .dah, .dit, .dah, .dit]
    ]

    /// Reverse lookup built once at load time. Used by `decode(_:)` and by
    /// `MorseTree` when a user's keyed sequence commits.
    static let sequenceToChar: [[MorseElement]: Character] = {
        var m: [[MorseElement]: Character] = [:]
        for (char, seq) in alphabet { m[seq] = char }
        return m
    }()

    // MARK: - Encode / decode

    /// Encode a string into a playback-ready frame schedule. Spaces in the
    /// input become word gaps; every other letter is separated by a letter
    /// gap. Characters not in the alphabet are dropped silently — the UI
    /// layer should filter input before calling this anyway.
    static func encode(_ text: String) -> [MorseFrame] {
        var out: [MorseFrame] = []
        let words = text.uppercased().split(separator: " ", omittingEmptySubsequences: true)
        for (wordIdx, word) in words.enumerated() {
            if wordIdx > 0 { out.append(.wordGap) }
            for (charIdx, char) in word.enumerated() {
                guard let elements = alphabet[char] else { continue }
                if charIdx > 0 { out.append(.letterGap) }
                for element in elements {
                    out.append(element == .dit ? .dit : .dah)
                }
            }
        }
        return out
    }

    /// Decode a single-letter sequence of elements to its character.
    /// Returns nil for undefined sequences (e.g. `[.dit, .dah, .dit, .dit, .dit, .dit, .dit, .dit]`).
    /// Callers should split their input on gap events before calling.
    static func decode(_ elements: [MorseElement]) -> Character? {
        sequenceToChar[elements]
    }
}
