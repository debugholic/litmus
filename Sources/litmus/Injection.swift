import ArgumentParser
import Foundation
import LitmusCore

/// Copying the project and writing the mutants into the copy.
///
/// Shared by `inject`, which stops there so the result can be read, and `run`,
/// which carries straight on. The two used to be separate steps a caller
/// stitched together by hand, passing the same scheme twice and carrying a
/// plan path between them.
/// Nothing to mutate, which is not a failure.
///
/// A branch that only touched tests or comments has nothing for Litmus to
/// change, and a pipeline that goes red for that is a pipeline people learn to
/// ignore. Thrown so the caller can say so and exit cleanly.
struct NothingToMutate: Error {
    let reason: String
}

struct Injection {
    let project: URL
    let workingCopy: URL
    let scope: ScopeOptions
    let harness: HarnessOptions

    func callAsFunction(verbose: Bool) throws -> ProjectInjection.Result {
        var changed: ChangedLines?
        if let base = scope.base(for: project) {
            let diff = try GitDiff.changed(since: base, in: project)

            guard !diff.isEmpty else {
                throw NothingToMutate(
                    reason: "no Swift file has changed since \(base)"
                )
            }

            changed = diff
            print("  changes since \(base)")
        } else {
            print("  the whole tree")
        }

        // Copied first, so the suite can run in the copy before any mutant is
        // in it: the scheme that runs every test exists only there.
        try ProjectInjection.clone(project, to: workingCopy)

        var coverage: Coverage?
        var tested: TestedScope?
        if scope.coverage {
            let (testHarness, lanes) = try harness.resolved(for: workingCopy, writeScheme: true) {
                print("  \($0)")
            }

            print("  measuring coverage — building and running the suite once…")

            let heartbeat = Heartbeat()
            heartbeat.begin()
            defer { heartbeat.end() }

            let measured = try Self.measure(testHarness, lane: lanes[0], in: workingCopy, heartbeat: heartbeat)
            let took = heartbeat.end()

            guard !measured.isEmpty else {
                throw ValidationError(
                    "the coverage run reported nothing — pass --no-coverage to skip this"
                )
            }

            print("  measured in \(Heartbeat.format(took ?? 0))"
                + " — \(measured.deadFiles) file(s) with nothing running in them")
            coverage = measured

            // The coverage run already built the tests, so it can say which
            // modules they are aimed at before anything is written.
            tested = testHarness.coverageScope()
            if let tested {
                print("  these tests are aimed at \(tested.modules.joined(separator: ", "))")
            }
        }

        let result = try ProjectInjection(
            include: scope.only,
            coverage: coverage,
            changed: changed,
            scope: tested
        ).inject(project: project, workingCopy: workingCopy) { if verbose { print("    \($0)") } }

        guard !result.mutants.isEmpty else {
            var why: [String] = []
            if result.unchanged > 0 { why.append("\(result.unchanged) outside the change") }
            if result.uncovered > 0 { why.append("\(result.uncovered) no test reaches") }

            throw NothingToMutate(reason: """
            nothing to mutate\(scope.only.map { " under '\($0)'" } ?? "")\
            \(why.isEmpty ? "" : " — \(why.joined(separator: ", "))")
            """)
        }

        return result
    }

    /// Runs the suite with coverage on.
    ///
    /// With Litmus's scheme of every test, a target that does not build or
    /// whose own tests fail is taken out and the run tried again: one broken
    /// target in seventy should not stop the other sixty-nine. Bounded,
    /// because each try is a build and a run of everything left.
    static func measure(
        _ harness: any TestHarness,
        lane: String,
        in workingCopy: URL,
        heartbeat: Heartbeat
    ) throws -> Coverage {
        let allTests = (harness as? Xcodebuild)?.scheme == AllTestsScheme.name

        for _ in 0..<10 {
            do {
                return try harness.coverage(lane: lane)
            } catch let failure as SuiteFailure where allTests {
                let failedBundles = (harness as? Xcodebuild).map {
                    TestedScope.failedTestTargets(inResultBundle: $0.coverageBundle)
                } ?? []
                let dropped = try AllTestsScheme.leaveOut(
                    failedIn: failure.log, failedBundles: failedBundles, in: workingCopy
                )
                guard !dropped.isEmpty else { throw failure }

                heartbeat.end()
                print("  leaving out \(dropped.joined(separator: ", ")) — it does not build, or its own tests fail")
                heartbeat.begin()
            }
        }

        return try harness.coverage(lane: lane)
    }

    /// One line saying what was left out, so a small run never looks like a
    /// clean bill of health for the whole project.
    static func scopeLine(_ result: ProjectInjection.Result) -> String {
        var dropped: [String] = []
        if result.outOfScope > 0 { dropped.append("\(result.outOfScope) file(s) the tests do not aim at") }
        if result.unchanged > 0 { dropped.append("\(result.unchanged) outside the change") }
        if result.uncovered > 0 { dropped.append("\(result.uncovered) unreachable") }

        let files = Set(result.mutants.map(\.fileName)).count
        let scope = "\(result.mutants.count) mutants across \(files) file(s)"

        return dropped.isEmpty ? scope : "\(scope), skipping \(dropped.joined(separator: " and "))"
    }
}

private extension String {
    var dim: String { self }
}
