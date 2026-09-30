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

    @Option(help: "How many times to run the whole suite.")
    var runs: Int = 10

    @Option(help: "Report format: plain or json.")
    var format: FlakyReport.Format = .plain

    @Option(help: "Write the report here instead of stdout.")
    var output: String?

    func validate() throws {
        guard runs >= 1 else { throw ValidationError("--runs has to be at least 1") }
        // One simulator does it all: the passes are in order, in one process.
        guard harness.workers == 1, harness.simulators.count <= 1 else {
            throw ValidationError("litmus flaky runs on one simulator; drop --workers, and pass one --simulators at most")
        }
    }

    func run() async throws {
        let startedAt = Date()
        let project = URL(fileURLWithPath: project).standardizedFileURL

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

        var targets: [TestedScope.TestTarget] = []
        var skipped: [(target: String, reason: String)] = []
        for target in scope.testTargets {
            let fit = FlakyDriver.fit(target)
            if let reason = fit.reason {
                skipped.append((target.name, reason))
            } else {
                targets.append(target)
                if let note = fit.note { skipped.append((target.name, note)) }
            }
        }
        guard !targets.isEmpty else {
            throw ValidationError("no test target has Swift Testing tests; litmus flaky reruns those only")
        }

        heartbeat.begin("  adding the driver to \(targets.count) test target(s) and rebuilding…")
        let prepared = try await xcodebuild.prepareFlaky(targets: targets, lane: lane)
        let buildTook = Date().timeIntervalSince(startedAt)
        heartbeat.end()

        var results: [FlakyRun] = []
        for target in targets {
            heartbeat.begin("  \(target.name): each test alone, the suite \(runs) time(s), each alone again…")
            let run = try await xcodebuild.runFlaky(prepared, target: target.name, lane: lane, runs: runs) { run in
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
