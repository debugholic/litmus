import Foundation

/// Serialises a run so it can be read by a person, a machine or Xcode.
public enum ReportFormat: String, Sendable, CaseIterable {
    case plain
    case json
    /// Stryker's viewer: every file's source, with each mutant on its line.
    case html
    /// The Stryker report schema, for tools that read it.
    case stryker
    /// Emits `warning:` lines Xcode picks up and shows beside the mutated line.
    case xcode
}

public struct Report: Sendable {
    let summary: MutationRun.Summary
    /// Where the mutated copy is and where its original is, so the HTML
    /// report can show the source as written. Without them it reads the
    /// files where the mutants say they are.
    let workingCopy: URL?
    let project: URL?

    public init(_ summary: MutationRun.Summary, workingCopy: URL? = nil, project: URL? = nil) {
        self.summary = summary
        self.workingCopy = workingCopy
        self.project = project
    }

    private var stryker: StrykerReport {
        let root = workingCopy ?? URL(fileURLWithPath: "/")
        return StrykerReport(summary, workingCopy: root, project: project ?? root)
    }

    public func rendered(as format: ReportFormat) throws -> String {
        switch format {
        case .plain: return plain()
        case .json: return try json()
        case .html: return try stryker.html()
        case .stryker: return try stryker.json()
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

        let gaps = FunctionGap.find(in: summary.results)
        guard !gaps.isEmpty else { return lines.joined(separator: "\n") }

        let untested = gaps.count { $0.status == .untested }
        lines.append("")
        lines.append("what to test — \(untested) untested, \(gaps.count - untested) partly tested:")

        let kindWidth = GapKind.allCases.map(\.rawValue.count).max() ?? 0
        for gap in gaps {
            lines.append("")
            lines.append("\(gap.status.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0))"
                + "\(gap.name)  \(gap.caught) of \(gap.scored) caught")
            for survivor in gap.survivors {
                let mutant = survivor.mutant
                let kind = mutant.gapKind.rawValue.padding(toLength: kindWidth, withPad: " ", startingAt: 0)
                lines.append("  \(location(of: survivor))  \(kind)  \(Self.what(mutant))")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// The change in one line: the code before and after, or what was
    /// removed. Long code is cut, since the line number finds the rest.
    static func what(_ mutant: Mutant) -> String {
        guard let change = mutant.change else { return mutant.description }

        func oneLine(_ code: String) -> String {
            let flat = code.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return flat.count > 60 ? String(flat.prefix(59)) + "…" : flat
        }

        if mutant.operator == "RemoveSideEffects" {
            return mutant.description
        }
        return "`\(oneLine(change.original))` → `\(oneLine(change.replacement))`"
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
}
