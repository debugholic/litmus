import Foundation

/// The lines a change touched.
///
/// Mutating only these is what makes a run fit inside a pull request. The whole
/// tree is the right scope for a nightly job; for a review it is thousands of
/// mutants on code nobody touched, and the answer for those has not changed
/// since the last run.
public struct ChangedLines: Sendable {
    let lines: [String: Set<Int>]

    public init(lines: [String: Set<Int>]) {
        self.lines = lines
    }

    public var isEmpty: Bool { lines.isEmpty }
    public var fileCount: Int { lines.count }

    /// Whether the change reached here.
    ///
    /// A file the diff never mentions is excluded outright: unlike coverage,
    /// silence here is an answer. Nothing in it changed.
    public func includes(path: String, line: Int) -> Bool {
        lines[path]?.contains(line) ?? false
    }

    /// Re-keys the diff, whose paths are relative to the repository, onto the
    /// absolute paths of the working copy.
    public func rebased(onto paths: [String]) -> ChangedLines {
        var rebased: [String: Set<Int>] = [:]

        for path in paths {
            guard let source = PathMatch.best(for: path, among: lines.keys) else { continue }
            rebased[path] = lines[source]
        }

        return ChangedLines(lines: rebased)
    }
}
