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
        // Pinned: the switch the error sits inside, or the flags on its line.
        // Otherwise every mutant in the file is a suspect.
        var pinned: [String: Set<String>] = [:]
        var wholeFile: Set<String> = []
        var parsed: [String: Parsed] = [:]

        for error in Self.errors(in: log) {
            let path = Self.canonical(error.path)
            guard path.hasPrefix(root), let inFile = byFile[path] else { continue }

            // Read and parsed once per file, however many errors are in it.
            guard let source = parsed[path] ?? Parsed(path: path) else { continue }
            parsed[path] = source

            if let flag = source.innermostFlag(line: error.line, column: error.column),
               let mutant = inFile.first(where: { MutationSwitch.flagName($0.switchName) == flag }) {
                pinned[path, default: []].insert(mutant.switchName)
                continue
            }

            let line = source.line(error.line)
            let named = inFile.filter { line.contains(MutationSwitch.flagName($0.switchName)) }
            if named.isEmpty {
                wholeFile.insert(path)
            } else {
                pinned[path, default: []].formUnion(named.map(\.switchName))
            }
        }

        var removed: [Mutant] = []
        var moved = 0

        for path in Set(pinned.keys).union(wholeFile) {
            let inFile = byFile[path] ?? []
            let copied = copies[path]
            let named = pinned[path] ?? []
            let ids = wholeFile.contains(path) ? Set(inFile.map(\.switchName)) : named

            // A call that does not build is a type the helpers do not take;
            // the copy of the expression takes any. Only an operator an error
            // points at is moved — an error nothing pins is not a call's — and
            // while one is, nothing else is taken out: the call is the likelier
            // fault, and the next build says whether it was.
            let toCopy = Set(inFile.filter { named.contains($0.switchName) && $0.isOperatorSwap }.map(\.switchName))
                .subtracting(copied)
            let pulled = toCopy.isEmpty ? ids : []
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

    /// The flag of the innermost switch around an error, read from the file.
    static func innermostFlag(at error: (path: String, line: Int, column: Int)) -> String? {
        Parsed(path: error.path)?.innermostFlag(line: error.line, column: error.column)
    }

    /// A working-copy file, read and parsed once.
    private struct Parsed {
        let lines: [Substring]
        let tree: SourceFileSyntax
        let converter: SourceLocationConverter

        init?(path: String) {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            tree = Parser.parse(source: text)
            converter = SourceLocationConverter(fileName: path, tree: tree)
        }

        func line(_ number: Int) -> String {
            number >= 1 && number <= lines.count ? String(lines[number - 1]) : ""
        }

        /// The flag of the innermost switch the position is inside: an
        /// operator's call, the ternary a copy or a replaced value sits in,
        /// or the `if !flag` a removed call is guarded by. Innermost, so an
        /// error in one mutant's code is not laid on the one around it.
        func innermostFlag(line: Int, column: Int) -> String? {
            let position = converter.position(ofLine: line, column: max(1, column))
            guard let token = tree.token(at: position) else { return nil }

            var current: Syntax? = Syntax(token)
            while let node = current {
                if let flag = Self.flag(of: node) { return flag }
                current = node.parent
            }
            return nil
        }

        private static func flag(of node: Syntax) -> String? {
            func name(_ expression: ExprSyntax?) -> String? {
                guard let text = expression?.as(DeclReferenceExprSyntax.self)?.baseName.text,
                      text.hasPrefix("__litmus_")
                else { return nil }
                return text
            }

            // `__litmus_add(flag, a, b)`
            if let call = node.as(FunctionCallExprSyntax.self),
               call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text.hasPrefix("__litmus_") == true {
                return name(call.arguments.first?.expression)
            }

            // `(flag ? mutated : original)`, unfolded as the parser leaves it.
            if let sequence = node.as(SequenceExprSyntax.self),
               sequence.elements.count == 3,
               sequence.elements.dropFirst().first?.is(UnresolvedTernaryExprSyntax.self) == true {
                return name(sequence.elements.first)
            }

            // `if !flag { removed() }`
            if let guarded = node.as(IfExprSyntax.self),
               guarded.conditions.count == 1,
               case let .expression(condition) = guarded.conditions.first?.condition,
               let negated = condition.as(PrefixOperatorExprSyntax.self),
               negated.operator.text == "!" {
                return name(negated.expression)
            }

            return nil
        }
    }

    /// `/path/File.swift:12:5: error: …`, or `error: /path/File.swift:12:5 …`
    ///
    /// The second is how `swift build` writes a syntax error since Swift 6.4,
    /// with nothing in the first form to go with it; missing it left a
    /// mutant that broke the parse with nothing to pin it on.
    ///
    /// Colour codes are dropped first: `swift build` colours the word
    /// "error" even when its output goes to a pipe.
    static func errors(in log: String) -> [(path: String, line: Int, column: Int)] {
        let plain = log.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression
        )

        return plain.split(separator: "\n").compactMap { entry in
            if entry.hasPrefix("error: ") {
                return located(entry.dropFirst("error: ".count), endingIn: " ")
            }
            guard let location = entry.range(of: ": error:") else { return nil }
            return located(entry[..<location.lowerBound], endingIn: nil)
        }
    }

    /// `/path/File.swift:12:5`, then `terminator` or the end of the text.
    private static func located(
        _ text: Substring, endingIn terminator: Character?
    ) -> (path: String, line: Int, column: Int)? {
        guard let swift = text.range(of: ".swift:") else { return nil }
        let path = text[..<swift.lowerBound] + ".swift"
        var rest = text[swift.upperBound...]
        if let terminator, let end = rest.firstIndex(of: terminator) {
            rest = rest[..<end]
        }

        let numbers = rest.split(separator: ":", omittingEmptySubsequences: false)
        guard numbers.count == 2, let line = Int(numbers[0]), let column = Int(numbers[1]) else {
            return nil
        }
        return (String(path), line, column)
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
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
