import SwiftSyntax

/// Where a mutation sits in the file.
///
/// `utf8Offset` is a byte count, as SwiftSyntax reports it. Litmus never uses
/// it to index into a `String`: characters and bytes only agree for ASCII, and
/// mixing the two silently moves edits in files with non-English comments.
/// It is carried for identity and reporting only.
struct SourcePosition: Equatable {
    let line: Int
    let column: Int
    let utf8Offset: Int

    init(line: Int, column: Int, utf8Offset: Int) {
        self.line = line
        self.column = column
        self.utf8Offset = utf8Offset
    }

    init(_ location: SourceLocation) {
        self.init(line: location.line, column: location.column, utf8Offset: location.offset)
    }
}

extension MutationSite {
    /// `<file stem>_<operator>_<line>_<column>_<utf8 offset>`
    ///
    /// The runner rebuilds this string from the plan to turn a mutation on, so
    /// it has to be assembled exactly as `Mutant.switchName` assembles it.
    static func switchName(
        fileName: String,
        operator name: String,
        position: SourcePosition
    ) -> String {
        [
            fileName,
            name,
            "\(position.line)",
            "\(position.column)",
            "\(position.utf8Offset)",
        ].joined(separator: "_")
    }
}
