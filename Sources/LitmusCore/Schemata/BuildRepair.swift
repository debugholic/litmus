import Foundation

/// Takes out the mutants a build rejected, so the rest can still run.
///
/// Every mutant is compiled into one build, so a single one the compiler
/// refuses would otherwise cost the whole run. The error names a line of the
/// working copy; the switches on that line are the suspects, and their file is
/// written again from the original without them. An error on a line with no
/// switch on it — a guarded call whose absence breaks something further down —
/// takes out the whole file's mutants, since nothing narrower can be pinned.
public struct BuildRepair: Sendable {
    let project: URL
    let workingCopy: URL
    let injector: SchemataInjector

    public init(project: URL, workingCopy: URL, injector: SchemataInjector = SchemataInjector()) {
        self.project = project
        self.workingCopy = workingCopy
        self.injector = injector
    }

    /// The mutants taken out, or none when the errors are not in any file
    /// Litmus wrote — then there is nothing it can undo.
    public func callAsFunction(log: String, mutants: [Mutant]) throws -> [Mutant] {
        // Compared with links resolved: the compiler, the file walk and the
        // caller do not all spell a temporary directory the same way.
        let root = Self.canonical(workingCopy.path) + "/"
        let byFile = Dictionary(grouping: mutants) { Self.canonical($0.filePath) }
        var suspects: [String: Set<String>] = [:]

        for error in Self.errors(in: log) {
            let path = Self.canonical(error.path)
            guard path.hasPrefix(root), let inFile = byFile[path] else { continue }

            let line = Self.line(error.line, of: path) ?? ""
            let named = inFile.filter { line.contains(MutationSwitch.flagName($0.switchName)) }
            let pulled = named.isEmpty ? inFile : named

            suspects[path, default: []].formUnion(pulled.map(\.switchName))
        }

        var removed: [Mutant] = []

        for (path, ids) in suspects {
            let inFile = byFile[path] ?? []
            let kept = Set(inFile.map(\.switchName)).subtracting(ids)
            let original = project.appendingPathComponent(String(path.dropFirst(root.count)))
            let source = try String(contentsOf: original, encoding: .utf8)

            let rewritten = kept.isEmpty
                ? source
                : injector.inject(source: source, path: path, keeping: kept).source
            try rewritten.write(toFile: path, atomically: true, encoding: .utf8)

            removed += inFile.filter { ids.contains($0.switchName) }
        }

        return removed
    }

    /// `/path/File.swift:12:5: error: …`
    ///
    /// Colour codes are dropped first: `swift build` colours the word
    /// "error" even when its output goes to a pipe.
    static func errors(in log: String) -> [(path: String, line: Int)] {
        let plain = log.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression
        )

        return plain.split(separator: "\n").compactMap { entry in
            let parts = entry.split(separator: ":", maxSplits: 4, omittingEmptySubsequences: false)
            guard
                parts.count == 5,
                parts[0].hasSuffix(".swift"),
                let line = Int(parts[1]),
                Int(parts[2]) != nil,
                parts[3].trimmingCharacters(in: .whitespaces) == "error"
            else { return nil }

            return (String(parts[0]), line)
        }
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private static func line(_ number: Int, of path: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard number >= 1, number <= lines.count else { return nil }
        return String(lines[number - 1])
    }
}
