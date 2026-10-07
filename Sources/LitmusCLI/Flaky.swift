import ArgumentParser
import Foundation
import LitmusCore

struct Flaky: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run the tests again and again, and report the ones whose result changes.",
        discussion: "Exits with 2 when a test is not stable, after writing the report."
    )

    @Option(help: "Project to test. It is never modified.")
    var project: String = "."

    @Option(help: "Only run the tests changed since this git ref, rather than every test.")
    var since: String?

    @Flag(help: """
    Only run the tests changed since the last commit, new files included. For \
    what a branch changed, use --since <base>.
    """)
    var changed = false

    @OptionGroup var device: DeviceOptions

    @Option(help: """
    How many times to run the tests together. 10 by default, for the whole \
    suite; 100 with --since or --changed, for the tests a change touched, \
    which are few.
    """)
    var runs: Int?

    @Option(help: """
    Hold back every awaited URLSession response by up to this many \
    milliseconds, at random, so a test that passes only when the network \
    answers fast or in order shows it. 0 turns it off.
    """)
    var jitter: Int = 300

    @Flag(help: """
    Rerun the tests that reach a server too. They run alone once and not \
    again otherwise, since each rerun is a request to it.
    """)
    var allowServer = false

    @Option(help: "Report format: plain, json or html.")
    var format: FlakyReport.Format = .plain

    @Option(help: "Write the report here instead of stdout.")
    var output: String?

    func validate() throws {
        guard (runs ?? 1) >= 1 else { throw ValidationError("--runs has to be at least 1") }
        guard since == nil || !changed else { throw ValidationError(Narrowing.conflict) }
        guard jitter >= 0 else { throw ValidationError("--jitter cannot be negative") }
    }

    func run() async throws {
        let startedAt = Date()
        let project = URL(fileURLWithPath: project).standardizedFileURL

        // With --since or --changed, only the tests that change touched, as
        // `litmus` then takes only the lines it changed.
        let narrowing = Narrowing(since: since, changed: self.changed)
        var changed: ChangedLines?
        // The changed tests that reach something that can vary; nil runs
        // every changed test.
        var risky: [ChangedTests.Span]?
        var calm: [String] = []
        if let narrowing {
            let diff = try narrowing.lines(in: project)
            // Said before anything is built: no test file, nothing to rerun.
            let testFiles = diff.paths.filter { path in
                (try? String(contentsOf: project.appendingPathComponent(path), encoding: .utf8))?
                    .contains("import Testing") == true
            }
            guard !testFiles.isEmpty else {
                print("no Swift Testing file has changed \(narrowing.since).")
                narrowing.leaveOut(to: "run every test").forEach { print($0) }
                return
            }
            changed = diff
            print("  tests changed \(narrowing.since)")

            // Before anything is built: a test that reaches nothing that
            // can vary comes out the same every time, and rerunning it
            // costs a build and a launch for nothing.
            let risk = FlakyRisk(root: project)
            var found: [ChangedTests.Span] = []
            var lines: [String] = []
            for path in testFiles.sorted() {
                let file = project.appendingPathComponent(path).path
                for test in ChangedTests.picked(inFile: file, changed: diff.lines(of: path)) {
                    if let finding = risk.finding(for: test.function) {
                        found.append(test.span)
                        lines.append("    \(test.name) — \(finding.factor), via \(finding.path.joined(separator: " → "))")
                    } else {
                        calm.append(test.name)
                    }
                }
            }
            print("  \(found.count + calm.count) changed test(s), \(found.count) reaching something that can vary:")
            lines.forEach { print($0) }
            if !calm.isEmpty {
                print("  left out, since nothing they reach can vary: \(FlakyReport.some(calm))")
            }
            guard !found.isEmpty else {
                print("no changed test reaches anything that can vary, so none is run again.")
                narrowing.leaveOut(to: "run every test anyway").forEach { print($0) }
                return
            }
            risky = found
        } else {
            print("  every test")
        }
        let runs = self.runs ?? (changed == nil ? 10 : 100)

        // Beside the mutation run's copy rather than in it, so neither run
        // deletes the other's files; and not under its name, so one run
        // clearing up after an earlier one does not stop this one.
        let mutationCopy = WorkingCopy.location(for: project)
        let working = ReportPages.flakyFolder(besides: mutationCopy)

        Interruption.install()
        try RunLock.acquire(for: working)
        try ProjectInjection.clone(project, to: working)

        // In the copy, before the first build, so the tests the build lists
        // and the ones the driver runs are the same code. With no jitter the
        // calls are still wrapped, to tell a test that reaches a server.
        let held = try NetworkJitter.apply(under: working, upTo: jitter)
        let calls = held.values.reduce(0, +)
        if calls > 0 {
            print(jitter > 0
                ? "  network responses held back up to \(jitter)ms, at \(calls) call(s) in \(held.count) file(s)"
                : "  network calls watched, at \(calls) call(s) in \(held.count) file(s)")
        }

        let (testHarness, lanes) = try HarnessOptions.resolve(device, workers: 1, for: working, writeScheme: true) { print("  \($0)") }
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
                if let risky { pick = pick?.filter { risky.contains($0) } }
                // A target the change did not touch needs no driver and no launch.
                guard pick?.isEmpty == false else { continue }
            }
            targets.append((target, pick))
            if let note = fit.note { skipped.append((target.name, note)) }
        }
        guard !targets.isEmpty else {
            if let narrowing {
                print("no Swift Testing test the build runs has changed \(narrowing.since).")
                narrowing.leaveOut(to: "run every test").forEach { print($0) }
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
            let run = try await xcodebuild.runFlaky(
                prepared, target: target.name, lane: lane, runs: runs, pick: pick, allowServer: allowServer
            ) { run in
                heartbeat.report(run.progress(of: runs))
            }
            heartbeat.end()
            let unstable = run.verdicts.count(where: \.isUnstable)
            let servers = run.verdicts.count(where: \.reachesServer)
            print("  \(target.name): \(run.tests.count) test(s), \(unstable) not stable"
                + (servers > 0 ? ", \(servers) reached a server and ran once" : ""))
            results.append(run)
        }

        let git = RunInfo.git(in: project)
        let report = FlakyReport(
            runs: results,
            skipped: skipped,
            asked: runs,
            scope: narrowing.map { "changed \($0.since)" },
            calm: calm,
            build: buildTook,
            duration: Date().timeIntervalSince(startedAt),
            run: RunInfo(
                date: startedAt, commit: git.commit, branch: git.branch, version: Litmus.version,
                operators: [], harness: "xcode, scheme \(xcodebuild.scheme), \(device.destination == nil ? "1 simulator" : lane)"
            ),
            mutation: ReportPages.linkToMutation(from: working)
        )
        let rendered = try report.rendered(as: format)

        if let output {
            try rendered.write(toFile: output, atomically: true, encoding: .utf8)
            print("\n  report written to \(output)")
        } else {
            print("\n" + rendered)
        }

        // Kept whatever was printed, as a mutation run keeps its own: a page
        // to open, and the same in JSON for a pipeline to read.
        let page = working.appendingPathComponent(ReportPages.flaky)
        try report.rendered(as: .html).write(to: page, atomically: true, encoding: .utf8)
        try ReportPages.reveal(in: mutationCopy.appendingPathComponent(ReportPages.mutation))
        try report.rendered(as: .json).write(
            to: working.appendingPathComponent("litmus-flaky-report.json"),
            atomically: true,
            encoding: .utf8
        )
        print("\n  report: \(Run.link(to: page))")

        // In GitHub Actions, the summary on the job's page and each test
        // that is not stable on the line it is declared.
        if let step = GitHubActions.current() {
            let copy = working.resolvingSymlinksInPath().path + "/"
            var files: [String: String] = [:]
            for (target, _) in targets {
                for file in target.files {
                    let resolved = URL(fileURLWithPath: file).resolvingSymlinksInPath().path
                    guard resolved.hasPrefix(copy) else { continue }
                    files[URL(fileURLWithPath: file).lastPathComponent] = project
                        .appendingPathComponent(String(resolved.dropFirst(copy.count))).path
                }
            }
            let github = report.github(files: files, workspace: step.workspace)
            try GitHubActions.append(github.summary, to: step)
            github.annotations.forEach { print($0) }
        }

        // After the report, so a failing run still leaves it to read. A test
        // whose result changes is what this command is for, so finding one
        // fails the pipeline without being asked to.
        let unstable = report.unstable.count
        if unstable > 0 {
            print("  \(unstable) test(s) not stable".red)
            throw ExitCode(2)
        }
    }
}

extension FlakyReport.Format: ExpressibleByArgument {}
