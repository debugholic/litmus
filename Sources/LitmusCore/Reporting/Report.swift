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
    /// What was run, when and on what.
    let run: RunInfo?
    /// To the flaky run's page, from the HTML report's summary.
    let flaky: ReportPages.Link?

    public init(
        _ summary: MutationRun.Summary,
        workingCopy: URL? = nil,
        project: URL? = nil,
        run: RunInfo? = nil,
        flaky: ReportPages.Link? = nil
    ) {
        self.summary = summary
        self.workingCopy = workingCopy
        self.project = project
        self.run = run
        self.flaky = flaky
    }

    private var stryker: StrykerReport {
        let root = workingCopy ?? URL(fileURLWithPath: "/")
        return StrykerReport(summary, workingCopy: root, project: project ?? root, run: run, flaky: flaky)
    }

    /// `took 12m 28s — build 1m 5s, launch and baseline 40s, mutants 10m 43s`
    static func took(_ summary: MutationRun.Summary) -> String? {
        guard summary.duration > 0 else { return nil }
        var parts: [String] = []
        // Under half a second, it would read "0s".
        if summary.phases.setup >= 0.5 { parts.append("setup \(duration(summary.phases.setup))") }
        if summary.phases.coverage >= 0.5 { parts.append("coverage \(duration(summary.phases.coverage))") }
        if summary.phases.build > 0 { parts.append("build \(duration(summary.phases.build))") }
        if summary.phases.baseline > 0 { parts.append("launch and baseline \(duration(summary.phases.baseline))") }
        if !parts.isEmpty { parts.append("mutants \(duration(summary.mutantTime))") }
        return "took \(duration(summary.total))" + (parts.isEmpty ? "" : " — " + parts.joined(separator: ", "))
    }

    static func duration(_ value: TimeInterval) -> String {
        let total = Int(value.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \(total % 3600 / 60)m"
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
            lines.append("Litmus score \(percent(score)) — caught of the mutants the tests reach")
        } else {
            lines.append("Litmus score —")
        }
        // A high score over a sliver of the code reads as a safe suite. The
        // share of all mutants caught says how much of the code is guarded.
        if let whole = summary.mutationScore, summary.noCoverage > 0 {
            lines.append("mutation score \(percent(whole)) — caught of every mutant, reached or not")
        }
        lines.append(counts(summary.results))
        // Beside the score, because it is about the score.
        lines += failedAlone()

        // One file says nothing a second time; several are where the weak one
        // hides behind the average.
        // A table for the whole before one per file: which module, or which
        // part of a single module, the tests leave alone.
        let areas = summary.areas
        if areas.count > 1 {
            let width = areas.map(\.name.count).max() ?? 0
            lines.append("")
            lines.append("by \(summary.areasAreModules ? "module" : "folder"), weakest first:")
            for area in areas {
                let score = area.score.map(percent) ?? "—"
                let padded = area.name.padding(toLength: width, withPad: " ", startingAt: 0)
                lines.append("  \(String(repeating: " ", count: max(0, 4 - score.count)))\(score)  \(padded)  \(counts(area.results))")
            }
        }

        // Only files with a score: a file the tests never reach says nothing
        // here, and one project listed 112 of them. They are counted below.
        let files = summary.files
        let scored = files.filter { $0.score != nil }
        if files.count > 1, !scored.isEmpty {
            let width = scored.map(\.path.count).max() ?? 0
            lines.append("")
            lines.append("by file, weakest first:")
            for file in scored {
                let score = file.score.map(percent) ?? "—"
                let padded = file.path.padding(toLength: width, withPad: " ", startingAt: 0)
                lines.append("  \(String(repeating: " ", count: max(0, 4 - score.count)))\(score)  \(padded)  \(counts(file.results))")
            }
            if files.count > scored.count {
                lines.append("  and \(files.count - scored.count) file(s) with nothing the tests reach")
            }
        }

        lines += slowest()

        let plan = TestPlan(summary.results)
        lines += unchecked(plan)
        lines += unreached(plan)

        // Last: what the numbers above were measured on.
        if let run { lines += ["", "run \(run.line)"] }
        if let took = Self.took(summary) { lines.append(took) }

        return lines.joined(separator: "\n")
    }

    /// Tests that pass in the suite and fail when run again on their own. A
    /// mutant runs the same way, so a kill that rests on them alone may be
    /// theirs rather than the mutant's.
    private func failedAlone() -> [String] {
        let tests = summary.failedAlone
        guard !tests.isEmpty else { return [] }

        var lines = ["", "\(tests.count) test(s) pass in the suite and fail when run again on their own — they depend on state left behind, or are flaky:"]
        for test in tests.prefix(10) {
            lines.append("  \(test.name)" + (test.file.map { "  (\($0))" } ?? ""))
        }
        if tests.count > 10 { lines.append("  and \(tests.count - 10) more") }
        let unsure = summary.unsureKills.count
        if unsure > 0 {
            lines.append("  \(unsure) kill(s) rest on these tests alone, and may not be the mutant's doing")
        }
        return lines
    }

    /// Functions a test runs through without noticing the change, each
    /// survivor in full: the tests are there, and a check is what is missing.
    private func unchecked(_ plan: TestPlan) -> [String] {
        guard !plan.unchecked.isEmpty else { return [] }

        let untested = plan.unchecked.count { $0.gap.status == .untested }
        var lines = ["", "what to test — \(untested) untested, \(plan.unchecked.count - untested) partly tested:"]

        let kindWidth = GapKind.allCases.map(\.rawValue.count).max() ?? 0
        for group in plan.groups {
            lines.append("")
            lines.append(group.owner + (Self.passedThrough(by: group.passedBy).map { " — \($0)" } ?? ""))
            for entry in group.entries {
                let gap = entry.gap
                let member = TestPlan.split(gap.name).member ?? gap.name
                lines.append("  \(gap.status.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0))"
                    + "\(member)  \(gap.caught) of \(gap.scored) caught")
                for survivor in gap.survivors {
                    let kind = survivor.gapKind.rawValue.padding(toLength: kindWidth, withPad: " ", startingAt: 0)
                    lines.append("    \(location(of: survivor))  \(kind)  \(Self.what(survivor.mutant))")
                }
                if entry.unreached > 0 {
                    lines.append("    and \(entry.unreached) more in it no test reaches")
                }
            }
        }
        return lines
    }

    /// Code no test runs, counted by file: listed mutant by mutant it was
    /// thousands of lines that all said the same thing.
    private func unreached(_ plan: TestPlan) -> [String] {
        guard !plan.unreached.isEmpty else { return [] }

        let root = MutationRun.Summary.commonDirectory(of: summary.results.map(\.mutant.filePath))
        let shown = plan.unreached.prefix(10)
        let width = String(shown.first?.count ?? 0).count

        var lines = [
            "",
            "no test reaches — \(plan.unreachedTotal) mutant(s) in \(plan.unreached.count) file(s), most first:",
        ]
        for file in shown {
            let path = root.isEmpty ? file.path : String(file.path.dropFirst(root.count))
            lines.append("  \(String(repeating: " ", count: max(0, width - String(file.count).count)))\(file.count)  \(path)")
        }
        if plan.unreached.count > shown.count {
            lines.append("  and \(plan.unreached.count - shown.count) more file(s)")
        }
        return lines
    }

    /// The five tests that cost the run most, when the probe timed them.
    /// A slow test is paid for once per mutant it reaches, so its time
    /// alone does not say how much it slows a run down.
    private func slowest() -> [String] {
        let timed = summary.tests.filter { $0.cost != nil }.prefix(5)
        guard !timed.isEmpty else { return [] }

        var lines = ["", "slowest tests — each runs once for every mutant it reaches:"]
        for score in timed {
            let cost = Self.seconds(score.cost ?? 0)
            let each = Self.seconds(score.test.duration ?? 0)
            lines.append("  \(String(repeating: " ", count: max(0, 7 - cost.count)))\(cost)"
                + "  \(each) × \(score.reached)  \(score.test.name)")
        }
        return lines
    }

    static func seconds(_ value: TimeInterval) -> String {
        value < 10 ? String(format: "%.1fs", value) : "\(Int(value.rounded()))s"
    }

    /// The tests that ran through a survivor and passed anyway: the ones
    /// that need the check. Three by name, and a count for the rest.
    static func passedThrough(by tests: [TestRef]) -> String? {
        guard !tests.isEmpty else { return nil }
        let named = tests.prefix(3).map(\.name).joined(separator: ", ")
        let more = tests.count > 3 ? " and \(tests.count - 3) more" : ""
        return "passed by: \(named)\(more)"
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
            "testStrength": summary.testStrength as Any,
            "mutationScore": summary.mutationScore as Any,
            "noCoverage": summary.noCoverage,
            "killed": summary.killed,
            "survived": summary.survived,
            "timeout": summary.timedOut,
            "unviable": summary.unviable,
            "error": summary.errored,
            "duration": summary.total,
            "run": [
                "date": run.map { ISO8601DateFormatter().string(from: $0.date) } as Any,
                "commit": run?.commit as Any,
                "branch": run?.branch as Any,
                "version": run?.version as Any,
                "operators": run?.operators as Any,
                "harness": run?.harness as Any,
                "setup": summary.phases.setup,
                "coverage": summary.phases.coverage,
                "build": summary.phases.build,
                "baseline": summary.phases.baseline,
                "mutants": summary.mutantTime,
            ] as [String: Any],
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
            "areas": summary.areas.map { area in
                [
                    "name": area.name,
                    "kind": summary.areasAreModules ? "module" : "folder",
                    "score": area.score as Any,
                    "killed": area.count(.killed),
                    "survived": area.count(.survived),
                    "timeout": area.count(.timedOut),
                    "noCoverage": area.count(.noCoverage),
                    "unviable": area.count(.unviable),
                    "error": area.count(.error),
                ] as [String: Any]
            },
            "tests": summary.tests.map { score in
                [
                    "name": score.test.name,
                    "file": score.test.file as Any,
                    "duration": score.test.duration as Any,
                    "reached": score.reached,
                    "killed": score.killed,
                ] as [String: Any]
            },
            "failedAlone": summary.failedAlone.map { test in
                ["id": test.id, "name": test.name, "file": test.file as Any] as [String: Any]
            },
            "unsureKills": summary.unsureKills.count,
            "mutants": summary.results.sorted(by: sortedByLocation).map { result in
                [
                    "file": result.mutant.fileName,
                    "line": result.mutant.line,
                    "column": result.mutant.column,
                    "operator": result.mutant.operator,
                    "description": result.mutant.description,
                    "verdict": result.verdict.rawValue,
                    "duration": result.duration,
                    "coveredBy": result.coveredBy.map(\.name),
                    "killedBy": result.killedBy.map(\.name),
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
        if count(.noCoverage) > 0 { parts.append("no coverage \(count(.noCoverage))") }
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
