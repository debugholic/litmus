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
    /// The files the change touched, by the paths it is keyed by.
    public var paths: [String] { Array(lines.keys) }

    /// The touched lines of one file; none when the change missed it.
    public func lines(of path: String) -> Set<Int> { lines[path] ?? [] }

    /// Whether the change reached here.
    ///
    /// A file the diff never mentions is excluded outright: unlike coverage,
    /// silence here is an answer. Nothing in it changed.
    public func includes(path: String, line: Int) -> Bool {
        lines[path]?.contains(line) ?? false
    }

    /// The same lines, keyed from inside `prefix`: a project's paths rather
    /// than its repository's. Files outside it are left out.
    func relative(to prefix: String) -> ChangedLines {
        guard !prefix.isEmpty else { return self }
        var relative: [String: Set<Int>] = [:]
        for (path, touched) in lines where path.hasPrefix(prefix) {
            relative[String(path.dropFirst(prefix.count))] = touched
        }
        return ChangedLines(lines: relative)
    }

    /// Re-keys the diff, whose paths are relative to the project, onto the
    /// absolute paths of the working copy.
    ///
    /// By the path under `root` when one is given and the diff has it: exact.
    /// Otherwise by the longest shared ending, which needs two components
    /// to agree and so never matched a file at the project's root.
    public func rebased(onto paths: [String], root: URL? = nil) -> ChangedLines {
        var rebased: [String: Set<Int>] = [:]
        let base = root.map { $0.path.hasSuffix("/") ? $0.path : $0.path + "/" }

        for path in paths {
            if let base, path.hasPrefix(base), let exact = lines[String(path.dropFirst(base.count))] {
                rebased[path] = exact
                continue
            }
            guard let source = PathMatch.best(for: path, among: lines.keys) else { continue }
            rebased[path] = lines[source]
        }

        return ChangedLines(lines: rebased)
    }
}
