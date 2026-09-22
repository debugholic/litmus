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
            print("changes since \(base)".dim)
        } else {
            print("the whole tree".dim)
        }

        var coverage: Coverage?
        if scope.coverage {
            print("measuring coverage…".dim)

            let (testHarness, lanes) = try harness.resolved(for: project) {
                print("  \($0)".dim)
            }
            let measured = try testHarness.coverage(lane: lanes[0])

            guard !measured.isEmpty else {
                throw ValidationError(
                    "the coverage run reported nothing — pass --no-coverage to skip this"
                )
            }

            coverage = measured
        }

        let result = try ProjectInjection(
            include: scope.only,
            coverage: coverage,
            changed: changed
        )(project: project, workingCopy: workingCopy) { if verbose { print("  \($0)".dim) } }

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

    /// One line saying what was left out, so a small run never looks like a
    /// clean bill of health for the whole project.
    static func scopeLine(_ result: ProjectInjection.Result) -> String {
        var dropped: [String] = []
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
