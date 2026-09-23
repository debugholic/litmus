import Foundation

/// The list of mutants written into a working copy, so a run can be repeated
/// or split across machines without injecting again.
public enum Plan {
    public static func write(_ mutants: [Mutant], workingCopy: URL, to url: URL) throws {
        let payload: [String: Any] = [
            "version": 1,
            "workingCopy": workingCopy.path,
            "mutants": mutants.map { mutant in
                [
                    "file": mutant.filePath,
                    "line": mutant.line,
                    "column": mutant.column,
                    "utf8Offset": mutant.utf8Offset,
                    "operator": mutant.operator,
                    "description": mutant.description,
                    "evaluatedOnce": mutant.evaluatedOnce,
                    "change": mutant.change.map { change in
                        [
                            "startLine": change.startLine,
                            "startColumn": change.startColumn,
                            "endLine": change.endLine,
                            "endColumn": change.endColumn,
                            "original": change.original,
                            "replacement": change.replacement,
                            "function": change.function as Any,
                        ] as [String: Any]
                    } as Any,
                ] as [String: Any]
            },
        ]

        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url)
    }

    public static func read(contentsOf url: URL) throws -> [Mutant] {
        let data = try Data(contentsOf: url)
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entries = root["mutants"] as? [[String: Any]]
        else {
            // Not ours — fall back to Muter's mapping file so an existing
            // injection can still be run.
            return try MutantPlan.load(contentsOf: url)
        }

        return entries.compactMap { entry in
            guard
                let file = entry["file"] as? String,
                let line = entry["line"] as? Int,
                let column = entry["column"] as? Int,
                let utf8Offset = entry["utf8Offset"] as? Int,
                let `operator` = entry["operator"] as? String
            else { return nil }

            return Mutant(
                filePath: file,
                line: line,
                column: column,
                utf8Offset: utf8Offset,
                operator: `operator`,
                description: entry["description"] as? String ?? `operator`,
                evaluatedOnce: entry["evaluatedOnce"] as? Bool ?? false,
                change: (entry["change"] as? [String: Any]).flatMap { change in
                    guard
                        let startLine = change["startLine"] as? Int,
                        let startColumn = change["startColumn"] as? Int,
                        let endLine = change["endLine"] as? Int,
                        let endColumn = change["endColumn"] as? Int,
                        let original = change["original"] as? String,
                        let replacement = change["replacement"] as? String
                    else { return nil }
                    return Change(
                        startLine: startLine, startColumn: startColumn,
                        endLine: endLine, endColumn: endColumn,
                        original: original, replacement: replacement,
                        function: change["function"] as? String
                    )
                }
            )
        }
    }
}
