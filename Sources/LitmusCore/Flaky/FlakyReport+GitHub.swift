import Foundation

extension FlakyReport {
    /// The job's summary and the lines to annotate, for a run in Actions.
    /// Each test that is not stable is an error on the line it is declared,
    /// found by the file name and line its id ends in.
    ///
    /// `files` maps a test file's name to its path in the checkout.
    public func github(files: [String: String], workspace: URL) -> (summary: String, annotations: [String]) {
        let unstable = self.unstable
        var lines = [unstable.isEmpty
            ? "### litmus flaky: every test passed every time"
            : "### litmus flaky: \(unstable.count) test(s) not stable"]
        let what = scope.map { "\(testCount) test(s) \($0)" } ?? "\(testCount) test(s)"
        lines.append("\(what), \(scope == nil ? "the suite" : "together") \(asked) time(s)")

        if !unstable.isEmpty {
            lines += ["", "| Test | Why | File |", "|---|---|---|"]
            for (_, verdict) in unstable {
                lines.append("| \(GitHubActions.cell(verdict.name)) | \(GitHubActions.cell(verdict.reasons.joined(separator: "; ")))"
                    + " | \(verdict.file ?? "") |")
            }
        }
        if !calm.isEmpty {
            lines += ["", "Left out \(calm.count) changed test(s) that reach nothing that can vary."]
        }
        if let run { lines += ["", "<sub>\(GitHubActions.cell(run.line))</sub>"] }

        let annotations = unstable.prefix(GitHubActions.annotationLimit).map { _, verdict in
            let place = Self.place(of: verdict.test)
            return GitHubActions.annotation(
                .error,
                file: place.flatMap { files[$0.file] }.map { GitHubActions.relative($0, to: workspace) },
                line: place?.line,
                title: "Not stable: \(verdict.name)",
                message: verdict.reasons.joined(separator: "; ")
            )
        }
        return (lines.joined(separator: "\n"), annotations)
    }

    /// `Module.Suite/test()/File.swift:12:5` gives `File.swift` and 12.
    static func place(of id: String) -> (file: String, line: Int)? {
        let parts = (id.split(separator: "/").last ?? "").split(separator: ":")
        guard parts.count >= 2, let line = Int(parts[1]) else { return nil }
        return (String(parts[0]), line)
    }
}
