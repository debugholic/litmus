import Foundation

/// What `litmus flaky` found, over every test target it ran.
public struct FlakyReport: Sendable {
    public enum Format: String, Sendable, CaseIterable {
        case plain, json
    }

    public let runs: [FlakyRun]
    /// Test targets left out, and why.
    public let skipped: [(target: String, reason: String)]
    /// How many times the suite was asked to run.
    public let asked: Int
    public let build: TimeInterval
    public let duration: TimeInterval
    public let run: RunInfo?

    public init(
        runs: [FlakyRun],
        skipped: [(target: String, reason: String)] = [],
        asked: Int,
        build: TimeInterval = 0,
        duration: TimeInterval = 0,
        run: RunInfo? = nil
    ) {
        self.runs = runs
        self.skipped = skipped
        self.asked = asked
        self.build = build
        self.duration = duration
        self.run = run
    }

    /// Every test that is not stable, with its target.
    public var unstable: [(target: String, verdict: FlakyRun.Verdict)] {
        runs.flatMap { run in run.verdicts.filter { !$0.isStable }.map { (run.target, $0) } }
    }

    public var testCount: Int { runs.map(\.tests.count).reduce(0, +) }

    public func rendered(as format: Format) throws -> String {
        switch format {
        case .plain: return plain()
        case .json: return try json()
        }
    }

    // MARK: - plain

    private func plain() -> String {
        var lines = ["litmus flaky — \(testCount) test(s) in \(runs.count) target(s): "
            + "each alone before, the suite \(asked) time(s), each alone again after"]

        let unstable = self.unstable
        if unstable.isEmpty {
            lines.append("")
            lines.append("every test passed every time")
        } else {
            lines.append("")
            lines.append("\(unstable.count) test(s) not stable:")
            let width = unstable.map { TerminalWidth.of($0.verdict.name) }.max() ?? 0
            for (target, verdict) in unstable {
                let pad = String(repeating: " ", count: max(0, width - TerminalWidth.of(verdict.name)))
                let place = [runs.count > 1 ? target : nil, verdict.file].compactMap { $0 }.joined(separator: " · ")
                lines.append("  \(verdict.name)\(pad)  \(verdict.reasons.joined(separator: "; "))"
                    + (place.isEmpty ? "" : "  (\(place))"))
            }
            lines.append("")
            lines.append("\(testCount - unstable.count) test(s) passed every time")
        }

        for run in runs {
            if let stop = run.stop {
                let what = stop.hung ? "stopped: a pass hung" : "the test process went down"
                let at = run.stoppedIn.map { "while \(run.names[$0] ?? $0) ran on its own" }
                    ?? "in \(stop.phase.rawValue) pass \(stop.index + 1)"
                lines.append("\(run.target): \(what) \(at); the passes after it did not run")
            } else if run.suiteRuns < asked {
                lines.append("\(run.target): the suite ran \(run.suiteRuns) of \(asked) time(s)")
            }
        }

        if !skipped.isEmpty {
            lines.append("")
            for (target, reason) in skipped {
                lines.append("left out \(target) — \(reason)")
            }
        }

        if let run { lines += ["", "run \(run.line)"] }
        if duration > 0 {
            lines.append("took \(Report.duration(duration))"
                + (build > 0 ? " — build \(Report.duration(build)), runs \(Report.duration(max(0, duration - build)))" : ""))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - json

    private func json() throws -> String {
        let payload: [String: Any] = [
            "suiteRuns": asked,
            "tests": testCount,
            "unstable": unstable.count,
            "duration": duration,
            "targets": runs.map { run in
                [
                    "name": run.target,
                    "suiteRuns": run.suiteRuns,
                    "finished": run.finished,
                    "stopped": run.stop.map { stop in
                        [
                            "phase": stop.phase.rawValue,
                            "index": stop.index,
                            "hung": stop.hung,
                            "test": run.stoppedIn as Any,
                        ] as [String: Any]
                    } as Any,
                    "tests": run.verdicts.map { verdict in
                        [
                            "id": verdict.test,
                            "name": verdict.name,
                            "file": verdict.file as Any,
                            "failed": verdict.failed,
                            "ran": verdict.ran,
                            "stable": verdict.isStable,
                            "reasons": verdict.reasons,
                        ] as [String: Any]
                    },
                ] as [String: Any]
            },
            "skipped": skipped.map { ["name": $0.target, "reason": $0.reason] },
            "run": [
                "date": run.map { ISO8601DateFormatter().string(from: $0.date) } as Any,
                "commit": run?.commit as Any,
                "branch": run?.branch as Any,
                "version": run?.version as Any,
                "harness": run?.harness as Any,
            ] as [String: Any],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
