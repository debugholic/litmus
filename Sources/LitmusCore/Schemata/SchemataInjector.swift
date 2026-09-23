import Foundation
import SwiftParser
import SwiftSyntax

/// Writes every mutant into a file, switched off.
///
/// The result compiles and behaves exactly like the original until the runner
/// sets one of the environment variables.
public struct SchemataInjector: Sendable {
    public struct Result: Sendable {
        public let mutants: [Mutant]
        public let source: String
    }

    public let operators: [String]

    /// Defaults to every operator Litmus knows.
    public init(operators: [String]? = nil) {
        self.operators = operators ?? MutationOperator.allCases.map(\.name)
    }

    public func callAsFunction(path: String) throws -> Result {
        let original = try String(contentsOfFile: path, encoding: .utf8)
        return inject(source: original, path: path)
    }

    /// `keeping` limits the file to those mutants, by switch name; nil keeps
    /// every one the operators find.
    func inject(source: String, path: String, keeping: Set<String>? = nil) -> Result {
        let tree = Parser.parse(source: source)
        let fileName = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let converter = SourceLocationConverter(fileName: path, tree: tree)

        // Collect across operators first. Two operators can target the same
        // expression, and all of their sites have to end up in one chain of
        // ternaries — switching twice would bury the second set inside the
        // first's else.
        var sites: [SourceSpan: [MutationSite]] = [:]

        for name in operators {
            guard let mutationOperator = MutationOperator(name: name) else { continue }

            let collector = SiteCollector(
                operator: mutationOperator,
                fileName: fileName,
                converter: converter
            )
            collector.walk(tree)

            for (span, found) in collector.sites {
                let kept = found.filter { keeping?.contains($0.id) ?? true }
                guard !kept.isEmpty else { continue }
                sites[span, default: []].append(contentsOf: kept)
            }
        }

        guard !sites.isEmpty else {
            return Result(mutants: [], source: source)
        }

        let rewritten = MutationRewrite(sites: sites)(tree).description

        // A site that did not reach the output would be scored as a survivor
        // the tests never had a chance to kill, so check for its flag before
        // the declarations are added rather than trusting the walk.
        let applied = sites.values.flatMap { $0 }
            .filter { rewritten.contains(MutationSwitch.flagName($0.id)) }
            .sorted { $0.position.utf8Offset < $1.position.utf8Offset }

        guard !applied.isEmpty else {
            return Result(mutants: [], source: source)
        }

        let mutants = applied.map { site in
            Mutant(
                filePath: path,
                line: site.position.line,
                column: site.position.column,
                utf8Offset: site.position.utf8Offset,
                operator: site.operator,
                description: site.description,
                evaluatedOnce: site.evaluatedOnce,
                change: site.change
            )
        }

        return Result(mutants: mutants, source: flagged(rewritten, for: applied))
    }

    /// Appends one flag per mutant.
    ///
    /// Order does not matter at file scope, so the declarations go at the end
    /// where they cannot disturb the file's header or its imports.
    private func flagged(_ source: String, for sites: [MutationSite]) -> String {
        var result = source

        // `getenv` comes through Foundation, and not every file imports it.
        // Re-importing a module that is already imported is harmless.
        if !result.contains("import Foundation") {
            result = "import Foundation\n" + result
        }

        let declarations = sites
            .map { MutationSwitch.declaration(id: $0.id) }
            .joined(separator: "\n")

        return result + """

        // Litmus mutation switches. Each reads the active mutant when it is
        // evaluated, so one process can run many mutants in turn.
        \(MutationSwitch.lookup)
        \(declarations)

        """
    }
}
