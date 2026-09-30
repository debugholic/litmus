import Testing

@testable import LitmusCore

@Suite("Terminal width")
struct TerminalWidthTests {
    @Test("counts Hangul and emoji as two columns, and escape sequences as none")
    func columns() {
        #expect(TerminalWidth.of("abc") == 3)
        #expect(TerminalWidth.of("북마크 뷰모델") == 13)
        #expect(TerminalWidth.of("✔ killed") == 8)
        #expect(TerminalWidth.of("🔥") == 2)
        #expect(TerminalWidth.of("\u{1B}[33mab\u{1B}[0m") == 2)
        // A file name as the file system gives it, the syllables in pieces.
        #expect(TerminalWidth.of("재생목록".decomposedStringWithCanonicalMapping) == 8)
    }

    /// Counted as characters, the Korean line below was cut too late and
    /// wrapped on the terminal.
    @Test("cuts to the columns a line takes, not its characters")
    func cutsWideText() {
        let line = "  measuring coverage testing 북마크 뷰모델 · 12 test(s) run  1m 05s"
        let cut = TerminalWidth.cut(line, to: 40)

        #expect(TerminalWidth.of(cut) <= 40)
        #expect(cut.hasSuffix("…"))
        #expect(TerminalWidth.cut(line, to: 200) == line)
    }

    @Test("keeps an escape sequence whole when it cuts")
    func keepsEscapes() {
        let cut = TerminalWidth.cut("\u{1B}[33mabcdef\u{1B}[0m", to: 4)

        #expect(cut == "\u{1B}[33mabc…")
        #expect(TerminalWidth.of(cut) == 4)
    }
}
