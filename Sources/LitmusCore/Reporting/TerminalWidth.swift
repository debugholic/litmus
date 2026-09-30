import Foundation

/// How much of a terminal line text takes, which is not how many characters
/// it has.
///
/// Hangul, kanji and most emoji take two columns each. A test suite named in
/// Korean, counted as one column a letter, was cut too late: the line wrapped,
/// and every redraw left the wrapped half behind.
public enum TerminalWidth {
    /// Columns `text` takes. Escape sequences take none.
    public static func of(_ text: String) -> Int {
        var total = 0
        var escape = Escape()
        for character in text where !escape.consume(character) {
            total += columns(character)
        }
        return total
    }

    /// `text` cut to `limit` columns, ending in "…" when anything was cut.
    /// Escape sequences are kept whole.
    public static func cut(_ text: String, to limit: Int) -> String {
        guard limit > 0, of(text) > limit else { return text }

        var kept = ""
        var used = 0
        var escape = Escape()
        for character in text {
            if escape.consume(character) {
                kept.append(character)
                continue
            }
            let width = columns(character)
            // One column is left for the ellipsis.
            guard used + width <= limit - 1 else { break }
            kept.append(character)
            used += width
        }
        return kept + "…"
    }

    private static func columns(_ character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first else { return 0 }
        if scalar.properties.isEmojiPresentation { return 2 }

        switch scalar.value {
        case 0x1100...0x115F,   // Hangul Jamo
             0x2E80...0x303E,   // CJK radicals and punctuation
             0x3041...0x33FF,   // kana, Hangul compatibility Jamo, CJK symbols
             0x3400...0x4DBF,   // CJK extension A
             0x4E00...0x9FFF,   // CJK ideographs
             0xA000...0xA4CF,   // Yi
             0xAC00...0xD7A3,   // Hangul syllables
             0xF900...0xFAFF,   // CJK compatibility ideographs
             0xFE30...0xFE4F,   // CJK compatibility forms
             0xFF00...0xFF60,   // fullwidth forms
             0xFFE0...0xFFE6,
             0x20000...0x3FFFD: // CJK extensions B and on
            return 2
        default:
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .enclosingMark, .format, .control:
                return 0
            default:
                return 1
            }
        }
    }

    /// Follows an escape sequence — `ESC [ … m` for a colour — through the
    /// characters that make it up.
    private struct Escape {
        private var state: State = .none

        private enum State { case none, started, control }

        /// Whether `character` belongs to an escape sequence.
        mutating func consume(_ character: Character) -> Bool {
            switch state {
            case .none:
                guard character == "\u{1B}" else { return false }
                state = .started
            case .started:
                state = character == "[" ? .control : .none
            case .control:
                // A control sequence ends at a letter or one of @[\]^_`{|}~.
                if let value = character.asciiValue, (0x40...0x7E).contains(value) {
                    state = .none
                }
            }
            return true
        }
    }
}
