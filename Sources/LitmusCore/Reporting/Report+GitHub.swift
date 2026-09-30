import Foundation

extension Report {
    /// The job's summary and the lines to annotate, for a run in Actions.
    ///
    /// The summary is what a reviewer reads first: the scores, then what to
    /// test. Annotations go on survivors, a function no test catches
    /// anything in first, since those are the ten Actions shows.
    public func github(workspace: URL) -> (summary: String, annotations: [String]) {
        let caught = summary.killed + summary.timedOut
        var lines: [String] = []

        let score = summary.score.map { "\(Int($0.rounded()))%" } ?? "—"
        lines.append("### Litmus score \(score)")
        var counts = ["caught \(caught)", "survived \(summary.survived)", "no test reaches \(summary.noCoverage)"]
        if summary.unviable > 0 { counts.append("did not build \(summary.unviable)") }
        if let whole = summary.mutationScore, summary.noCoverage > 0 {
            counts.insert("mutation score \(Int(whole.rounded()))%", at: 0)
        }
        lines.append(counts.joined(separator: " · "))
        if let took = Self.took(summary) { lines += ["", took] }

        // Untested functions first: nothing there catches anything.
        let survivors = TestPlan(summary.results).unchecked
            .sorted { ($0.gap.status == .untested ? 0 : 1) < ($1.gap.status == .untested ? 0 : 1) }
            .flatMap { entry in entry.gap.survivors.filter { $0.verdict == .survived }.map { (entry.gap, $0) } }

        if !survivors.isEmpty {
            lines += ["", "#### What to test", "", "| Where | Status | Change | What to add |", "|---|---|---|---|"]
            for (gap, survivor) in survivors.prefix(20) {
                let place = "`\(survivor.mutant.fileName):\(survivor.mutant.line)` \(GitHubActions.cell(gap.name))"
                lines.append("| \(place) | \(gap.status.rawValue) | \(GitHubActions.cell(Self.what(survivor.mutant)))"
                    + " | \(survivor.gapKind.hint) |")
            }
            if survivors.count > 20 {
                lines.append("")
                lines.append("and \(survivors.count - 20) more; every one is in the HTML report")
            }
        }
        if let run { lines += ["", "<sub>\(GitHubActions.cell(run.line))</sub>"] }

        let annotations = survivors.prefix(GitHubActions.annotationLimit).map { gap, survivor in
            GitHubActions.annotation(
                .warning,
                file: GitHubActions.relative(original(survivor.mutant.filePath), to: workspace),
                line: survivor.mutant.line,
                title: "No test noticed this change (\(gap.status.rawValue) \(gap.name))",
                message: "\(Self.what(survivor.mutant).replacingOccurrences(of: "`", with: "")) — \(survivor.gapKind.hint)"
            )
        }
        return (lines.joined(separator: "\n"), annotations)
    }

    /// A mutant's file where the project has it, not in the working copy.
    func original(_ path: String) -> String {
        guard let workingCopy, let project else { return path }
        let root = GitHubActions.canonical(workingCopy.path) + "/"
        let resolved = GitHubActions.canonical(path)
        guard resolved.hasPrefix(root) else { return path }
        return project.appendingPathComponent(String(resolved.dropFirst(root.count))).path
    }
}
