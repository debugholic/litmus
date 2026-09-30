import ArgumentParser
import Foundation
import LitmusCore

struct Flaky: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run the tests again and again, and report the ones whose result changes."
    )

    @Option(help: "Project to test. It is never modified.")
    var project: String = "."

    @OptionGroup var harness: HarnessOptions

    @Option(help: "Only run the tests changed since this git ref.")
    var since: String?

    @Flag(help: "Run every test, not only the ones this branch changed.")
    var all = false

    @Option(help: """
    How many times to run the tests together. 100 by default for the tests a \
    change touched, which are few; 10 with --all, which runs the whole suite.
    """)
    var runs: Int?

    @Option(help: "Report format: plain or json.")
    var format: FlakyReport.Format = .plain

    @Option(help: "Write the report here instead of stdout.")
    var output: String?

    func validate() throws {
        guard (runs ?? 1) >= 1 else { throw ValidationError("--runs has to be at least 1") }
        guard since == nil || !all else { throw ValidationError("pass --since or --all, not both") }
        // One simulator does it all: the passes are in order, in one process.
        guard harness.workers == 1, harness.simulators.count <= 1 else {
            throw ValidationError("litmus flaky runs on one simulator; drop --workers, and pass one --simulators at most")
        }
    }

    func run() async throws {
        let startedAt = Date()
        let project = URL(fileURLWithPath: project).standardizedFileURL

        // The tests this branch changed, as `litmus` takes the lines it
        // changed. The existing suite already runs once in the pipeline;
        // repeating it here would be paying for that again.
        let base = all ? nil : (since ?? Discovery.defaultBase(in: project))
        var changed: ChangedLines?
        if let base {
            let diff = try GitDiff.changed(since: base, in: project)
            // Said before anything is built: no test file, nothing to rerun.
            let testFiles = diff.paths.filter { path in
                (try? String(contentsOf: project.appendingPathComponent(path), encoding: .utf8))?
                    .contains("import Testing") == true
            }
            guard !testFiles.isEmpty else {
                print("no Swift Testing file has changed since \(base).")
                print("Pass --all to run every test.")
                return
            }
            changed = diff
            print("  tests changed since \(base)")
        } else {
            print("  every test")
        }
        let runs = self.runs ?? (changed == nil ? 10 : 100)

        // Beside the mutation run's copy rather than in it, so neither run
        // deletes the other's files; and not under its name, so one run
        // clearing up after an earlier one does not stop this one.
        let mutationCopy = WorkingCopy.location(for: project)
        let working = mutationCopy.deletingLastPathComponent()
            .appendingPathComponent("flaky")
            .appendingPathComponent(mutationCopy.lastPathComponent)

        Interruption.install()
        try RunLock.acquire(for: working)
        try ProjectInjection.clone(project, to: working)

        let (testHarness, lanes) = try harness.resolved(for: working, writeScheme: true) { print("  \($0)") }
        guard let xcodebuild = testHarness as? Xcodebuild else {
            throw ValidationError("litmus flaky runs Xcode projects for now; this one runs with swift test")
        }
        let lane = lanes[0]

        let heartbeat = Heartbeat.shared
        heartbeat.begin("  building the tests…")
        let built = try await xcodebuild.build(lane: lane)
        heartbeat.end()

        guard let scope = xcodebuild.testedScope(built), !scope.testTargets.isEmpty else {
            throw ValidationError("could not tell which test targets the build has")
        }

        // Each target that can run, with the spans of its changed tests; nil
        // spans run all of its tests.
        var targets: [(target: TestedScope.TestTarget, pick: [ChangedTests.Span]?)] = []
        var skipped: [(target: String, reason: String)] = []
        for target in scope.testTargets {
            let fit = FlakyDriver.fit(target)
            if let reason = fit.reason {
                if changed == nil { skipped.append((target.name, reason)) }
                continue
            }
            var pick: [ChangedTests.Span]?
            if let changed {
                let lines = changed.rebased(onto: target.files, root: working)
                pick = target.files.flatMap { ChangedTests.spans(ofFile: $0, changed: lines.lines(of: $0)) }
                // A target the change did not touch needs no driver and no launch.
                guard pick?.isEmpty == false else { continue }
            }
            targets.append((target, pick))
            if let note = fit.note { skipped.append((target.name, note)) }
        }
        guard !targets.isEmpty else {
            if let base {
                print("no Swift Testing test the build runs has changed since \(base).")
                print("Pass --all to run every test.")
                return
            }
            throw ValidationError("no test target has Swift Testing tests; litmus flaky reruns those only")
        }

        heartbeat.begin("  adding the driver to \(targets.count) test target(s) and rebuilding…")
        let prepared = try await xcodebuild.prepareFlaky(targets: targets.map(\.target), lane: lane)
        let buildTook = Date().timeIntervalSince(startedAt)
        heartbeat.end()

        var results: [FlakyRun] = []
        for (target, pick) in targets {
            let together = pick == nil ? "the suite" : "the changed tests together"
            heartbeat.begin("  \(target.name): each test alone, \(together) \(runs) time(s), each alone again…")
            let run = try await xcodebuild.runFlaky(prepared, target: target.name, lane: lane, runs: runs, pick: pick) { run in
                heartbeat.report(run.progress(of: runs))
            }
            heartbeat.end()
            let unstable = run.verdicts.count { !$0.isStable }
            print("  \(target.name): \(run.tests.count) test(s), \(unstable) not stable")
            results.append(run)
        }

        let git = RunInfo.git(in: project)
        let report = FlakyReport(
            runs: results,
            skipped: skipped,
            asked: runs,
            scope: base.map { "changed since \($0)" },
            build: buildTook,
            duration: Date().timeIntervalSince(startedAt),
            run: RunInfo(
                date: startedAt, commit: git.commit, branch: git.branch, version: Litmus.version,
                operators: [], harness: "xcode, scheme \(xcodebuild.scheme), \(harness.destination == nil ? "1 simulator" : lane)"
            )
        )
        let rendered = try report.rendered(as: format)

        if let output {
            try rendered.write(toFile: output, atomically: true, encoding: .utf8)
            print("\n  report written to \(output)")
        } else {
            print("\n" + rendered)
        }
    }
}

extension FlakyReport.Format: ExpressibleByArgument {}
