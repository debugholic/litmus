import Foundation
import Testing

@testable import LitmusCore

@Suite("Mutant switch name")
struct MutantSwitchNameTests {
    private func mutant(
        path: String = "/tmp/Project/Sources/PlayerControlViewModel+Bookmark.swift",
        line: Int = 24,
        column: Int = 49,
        utf8Offset: Int = 885,
        operator name: String = "ChangeLogicalConnector"
    ) -> Mutant {
        Mutant(
            filePath: path,
            line: line,
            column: column,
            utf8Offset: utf8Offset,
            operator: name,
            description: "changed && to ||"
        )
    }

    /// The injected source reads this exact string, so the shape is a contract,
    /// not a formatting choice.
    @Test("is the file stem, operator and position joined with underscores")
    func matchesInjectedName() {
        #expect(
            mutant().switchName
                == "PlayerControlViewModel+Bookmark_ChangeLogicalConnector_24_49_885"
        )
    }

    @Test("keeps a plus in the file name")
    func keepsPlusInStem() {
        #expect(mutant().switchName.contains("PlayerControlViewModel+Bookmark"))
    }

    @Test("drops the directory and the extension")
    func usesOnlyTheStem() {
        let name = mutant(path: "/a/very/deep/path/MediaItem.swift").switchName

        #expect(name.hasPrefix("MediaItem_"))
        #expect(!name.contains("/"))
        #expect(!name.contains(".swift"))
    }

    @Test("distinguishes two mutants on the same line")
    func separatesByColumn() {
        let first = mutant(column: 49, utf8Offset: 885)
        let second = mutant(column: 66, utf8Offset: 902)

        #expect(first.switchName != second.switchName)
    }
}

@Suite("Mutant file name")
struct MutantFileNameTests {
    @Test("is the last path component")
    func lastComponent() {
        let mutant = Mutant(
            filePath: "/a/b/MediaItem.swift",
            line: 1, column: 1, utf8Offset: 0,
            operator: "RelationalOperatorReplacement",
            description: "changed == to !="
        )

        #expect(mutant.fileName == "MediaItem.swift")
    }
}
