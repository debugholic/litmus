import Foundation
import SwiftParser
import SwiftSyntax

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
    /// Sites sent back from a call to a copy, by file. Kept across rounds:
    /// every rewrite of a file starts again from the original.
    private let copies = Copies()

    public init(project: URL, workingCopy: URL, injector: SchemataInjector = SchemataInjector()) {
        self.project = project
        self.workingCopy = workingCopy
        self.injector = injector
    }

    /// What a round did: mutants taken out, and mutants moved from a call
    /// back to a copy of their expression, which still run.
    public struct Outcome: Sendable {
        public let removed: [Mutant]
        public let moved: Int

        /// Nothing written: the errors are not in any file Litmus wrote, and
        /// there is nothing it can undo.
        public var changedNothing: Bool { removed.isEmpty && moved == 0 }
    }

    public func callAsFunction(log: String, mutants: [Mutant]) throws -> Outcome {
        // Compared with links resolved: the compiler, the file walk and the
        // caller do not all spell a temporary directory the same way.
        let root = Self.canonical(workingCopy.path) + "/"
        let byFile = Dictionary(grouping: mutants) { Self.canonical($0.filePath) }
        var suspects: [String: Set<String>] = [:]

        for error in Self.errors(in: log) {
            let path = Self.canonical(error.path)
            guard path.hasPrefix(root), let inFile = byFile[path] else { continue }

            let line = Self.line(error.line, of: path) ?? ""
            var named = inFile.filter { line.contains(MutationSwitch.flagName($0.switchName)) }

            // An operator's call can run over several lines, and the error
            // point at an operand on one without the flag.
            if named.isEmpty, let flag = Self.enclosingCallFlag(at: error, in: path) {
                named = inFile.filter { MutationSwitch.flagName($0.switchName) == flag }
            }

            let pulled = named.isEmpty ? inFile : named
            suspects[path, default: []].formUnion(pulled.map(\.switchName))
        }

        var removed: [Mutant] = []
        var moved = 0

        for (path, ids) in suspects {
            let inFile = byFile[path] ?? []
            let copied = copies[path]

            // A call that does not build is a type the helpers do not take;
            // the copy of the expression takes any. Only a copy that fails
            // too is taken out.
            let toCopy = Set(inFile.filter { ids.contains($0.switchName) && $0.isOperatorSwap }.map(\.switchName))
                .subtracting(copied)
            let pulled = ids.subtracting(toCopy)
            copies[path] = copied.union(toCopy)
            moved += toCopy.count

            let kept = Set(inFile.map(\.switchName)).subtracting(pulled)
            let original = project.appendingPathComponent(String(path.dropFirst(root.count)))
            let source = try String(contentsOf: original, encoding: .utf8)

            let rewritten = kept.isEmpty
                ? source
                : injector.inject(source: source, path: path, keeping: kept, copied: copies[path]).source
            try rewritten.write(toFile: path, atomically: true, encoding: .utf8)

            removed += inFile.filter { pulled.contains($0.switchName) }
        }

        return Outcome(removed: removed, moved: moved)
    }

    /// The flag passed to the `__litmus_` call around an error, if there is
    /// one: the innermost, since calls nest as operators do.
    static func enclosingCallFlag(at error: (path: String, line: Int, column: Int), in path: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let tree = Parser.parse(source: text)
        let converter = SourceLocationConverter(fileName: path, tree: tree)
        let position = converter.position(ofLine: error.line, column: max(1, error.column))
        guard let token = tree.token(at: position) else { return nil }

        var current: Syntax? = Syntax(token)
        while let node = current {
            if let call = node.as(FunctionCallExprSyntax.self),
               call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text.hasPrefix("__litmus_") == true,
               let flag = call.arguments.first?.expression.as(DeclReferenceExprSyntax.self)?.baseName.text {
                return flag
            }
            current = node.parent
        }
        return nil
    }

    /// `/path/File.swift:12:5: error: …`
    ///
    /// Colour codes are dropped first: `swift build` colours the word
    /// "error" even when its output goes to a pipe.
    static func errors(in log: String) -> [(path: String, line: Int, column: Int)] {
        let plain = log.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression
        )

        return plain.split(separator: "\n").compactMap { entry in
            let parts = entry.split(separator: ":", maxSplits: 4, omittingEmptySubsequences: false)
            guard
                parts.count == 5,
                parts[0].hasSuffix(".swift"),
                let line = Int(parts[1]),
                let column = Int(parts[2]),
                parts[3].trimmingCharacters(in: .whitespaces) == "error"
            else { return nil }

            return (String(parts[0]), line, column)
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

/// Sites moved back to a copy, by file, shared by every copy of a repair.
private final class Copies: @unchecked Sendable {
    private let lock = NSLock()
    private var byPath: [String: Set<String>] = [:]

    subscript(path: String) -> Set<String> {
        get { lock.lock(); defer { lock.unlock() }; return byPath[path] ?? [] }
        set { lock.lock(); defer { lock.unlock() }; byPath[path] = newValue }
    }
}

private extension Mutant {
    /// Switched by an `OperatorCall`, which a copy can stand in for.
    var isOperatorSwap: Bool {
        TokenOperator(rawValue: `operator`) != nil || `operator` == MutationOperator.swapTernary.name
    }
}
