import Foundation

/// Serialises a run so it can be read by a person, a machine or Xcode.
public enum ReportFormat: String, Sendable, CaseIterable {
    case plain
    case json
    case html
    /// Emits `warning:` lines Xcode picks up and shows beside the mutated line.
    case xcode
}

public struct Report: Sendable {
    let summary: MutationRun.Summary

    public init(_ summary: MutationRun.Summary) {
        self.summary = summary
    }

    public func rendered(as format: ReportFormat) throws -> String {
        switch format {
        case .plain: return plain()
        case .json: return try json()
        case .html: return html()
        case .xcode: return xcode()
        }
    }

    // MARK: - plain

    private func plain() -> String {
        var lines: [String] = []

        if let score = summary.score {
            lines.append("Litmus score \(percent(score))")
        } else {
            lines.append("Litmus score —")
        }
        lines.append(counts(summary.results))

        // One file says nothing a second time; several are where the weak one
        // hides behind the average.
        let files = summary.files
        if files.count > 1 {
            let width = files.map(\.path.count).max() ?? 0
            lines.append("")
            lines.append("by file, weakest first:")
            for file in files {
                let score = file.score.map(percent) ?? "—"
                let padded = file.path.padding(toLength: width, withPad: " ", startingAt: 0)
                lines.append("  \(String(repeating: " ", count: max(0, 4 - score.count)))\(score)  \(padded)  \(counts(file.results))")
            }
        }

        let survivors = summary.results.filter { $0.verdict == .survived }
        guard !survivors.isEmpty else { return lines.joined(separator: "\n") }

        lines.append("")
        lines.append("survived — nothing failed when this changed:")
        for result in survivors.sorted(by: sortedByLocation) {
            lines.append("  \(location(of: result))  \(result.mutant.description)")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - json

    private func json() throws -> String {
        let payload: [String: Any] = [
            "score": summary.score as Any,
            "killed": summary.killed,
            "survived": summary.survived,
            "timeout": summary.timedOut,
            "unviable": summary.unviable,
            "error": summary.errored,
            "duration": summary.duration,
            "files": summary.files.map { file in
                [
                    "path": file.path,
                    "score": file.score as Any,
                    "killed": file.count(.killed),
                    "survived": file.count(.survived),
                    "timeout": file.count(.timedOut),
                    "unviable": file.count(.unviable),
                    "error": file.count(.error),
                ] as [String: Any]
            },
            "mutants": summary.results.sorted(by: sortedByLocation).map { result in
                [
                    "file": result.mutant.fileName,
                    "line": result.mutant.line,
                    "column": result.mutant.column,
                    "operator": result.mutant.operator,
                    "description": result.mutant.description,
                    "verdict": result.verdict.rawValue,
                    "duration": result.duration,
                ] as [String: Any]
            },
        ]

        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - xcode

    /// One line per surviving mutant, in the format Xcode parses into a warning.
    ///
    /// Killed mutants are left out: they are the good case, and reporting them
    /// would bury the holes in noise.
    private func xcode() -> String {
        summary.results
            .filter { $0.verdict == .survived }
            .sorted(by: sortedByLocation)
            .map { result in
                "\(result.mutant.filePath):\(result.mutant.line):\(result.mutant.column): "
                    + "warning: Litmus: \(result.mutant.description) — no test failed"
            }
            .joined(separator: "\n")
    }

    // MARK: - html

    private func html() -> String {
        let rows = summary.results.sorted(by: sortedByLocation).map { result in
            """
            <tr class="\(result.verdict.rawValue)">
              <td>\(escape(result.mutant.fileName))</td>
              <td class="num">\(result.mutant.line)</td>
              <td>\(escape(result.mutant.description))</td>
              <td>\(result.verdict.rawValue)</td>
            </tr>
            """
        }.joined(separator: "\n")

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <title>Litmus report</title>
        <style>
          :root { color-scheme: light dark; }
          body { font: 15px -apple-system, system-ui, sans-serif; margin: 3rem auto; max-width: 60rem; padding: 0 1rem; }
          .score { font-size: 3rem; font-weight: 600; }
          table { border-collapse: collapse; width: 100%; margin-top: 2rem; }
          th, td { text-align: left; padding: .5rem .75rem; border-bottom: 1px solid color-mix(in srgb, currentColor 15%, transparent); }
          .num { text-align: right; font-variant-numeric: tabular-nums; }
          .survived { background: color-mix(in srgb, crimson 12%, transparent); }
          .error, .unviable { opacity: .55; }
        </style>
        </head>
        <body>
        <p class="score">\(summary.score.map(percent) ?? "—")</p>
        <p>\(escape(counts(summary.results).replacingOccurrences(of: " / ", with: " · ")))</p>
        <table>
        <thead><tr><th>File</th><th class="num">Line</th><th>Change</th><th>Verdict</th></tr></thead>
        <tbody>
        \(rows)
        </tbody>
        </table>
        </body>
        </html>
        """
    }

    // MARK: - helpers

    /// `killed 3 / survived 1 / error 0`, with timeouts and unviable mutants
    /// only when there are any.
    private func counts(_ results: [MutantResult]) -> String {
        func count(_ verdict: Verdict) -> Int { results.count { $0.verdict == verdict } }

        var parts = ["killed \(count(.killed))", "survived \(count(.survived))"]
        if count(.timedOut) > 0 { parts.append("timeout \(count(.timedOut))") }
        if count(.unviable) > 0 { parts.append("unviable \(count(.unviable))") }
        parts.append("error \(count(.error))")
        return parts.joined(separator: " / ")
    }

    private func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    private func location(of result: MutantResult) -> String {
        "\(result.mutant.fileName):\(result.mutant.line)"
    }

    private func sortedByLocation(_ lhs: MutantResult, _ rhs: MutantResult) -> Bool {
        (lhs.mutant.fileName, lhs.mutant.line) < (rhs.mutant.fileName, rhs.mutant.line)
    }

    private func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
