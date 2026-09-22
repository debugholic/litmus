import ArgumentParser
import Foundation
import LitmusCore
import Rainbow

struct Inject: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Copy the project and write every mutant into the copy, switched off."
    )

    @Option(help: "Project to copy. It is never modified.")
    var project: String

    @Option(help: "Where to put the working copy. Defaults to <project>_litmus.")
    var output: String?

    @Option(help: "Only mutate files whose path contains this text.")
    var only: String?

    @Option(help: "Where to write the plan. Defaults to <working copy>/litmus-plan.json.")
    var plan: String?

    @Flag(help: "Run the suite once with coverage first, and skip what it never reaches.")
    var skipCoverage = false

    @Option(help: "Only mutate lines changed since this git ref, as a review would look at.")
    var changedSince: String?

    @OptionGroup var harness: HarnessOptions

    func run() async throws {
        let project = URL(fileURLWithPath: project).standardizedFileURL
        let workingCopy = output.map { URL(fileURLWithPath: $0) }
            ?? project.deletingLastPathComponent()
                .appendingPathComponent(project.lastPathComponent + "_litmus")

        var changed: ChangedLines?
        if let changedSince {
            let diff = try GitDiff.changed(since: changedSince, in: project)

            guard !diff.isEmpty else {
                throw ValidationError("nothing changed since '\(changedSince)'")
            }

            changed = diff

            // Said as "in the diff", not "to be mutated". The diff covers test
            // files and anything else written in Swift, and injection leaves
            // those alone; the count below is the one that says what ran.
            print("\(diff.fileCount) Swift file(s) in the diff against \(changedSince)")
        }

        // Measured on the project as written. Positions in a plan are
        // positions in the original file, and injecting moves every line below
        // the first mutant.
        var coverage: Coverage?
        if skipCoverage {
            print("measuring coverage first…")

            let (testHarness, lanes) = try harness.resolved(for: project)
            let measured = try testHarness.coverage(lane: lanes[0])

            guard !measured.isEmpty else {
                throw ValidationError("the coverage run reported nothing")
            }

            coverage = measured
            print("  \(measured.deadFiles) file(s) with nothing running in them\n")
        }

        print("copying to \(workingCopy.path)…")

        let result = try ProjectInjection(include: only, coverage: coverage, changed: changed)(
            project: project,
            workingCopy: workingCopy
        ) { print("  \($0)") }

        guard !result.mutants.isEmpty else {
            throw ValidationError("nothing to mutate"
                + (only.map { " under '\($0)'" } ?? "")
                + (result.unchanged > 0
                    ? "; \(result.unchanged) were outside the change"
                    : "")
                + (result.uncovered > 0
                    ? "; \(result.uncovered) were unreachable"
                    : ""))
        }

        let planURL = plan.map { URL(fileURLWithPath: $0) }
            ?? workingCopy.appendingPathComponent("litmus-plan.json")
        try Plan.write(result.mutants, workingCopy: workingCopy, to: planURL)

        print("""

          \(result.mutants.count) mutants across \
        \(Set(result.mutants.map(\.fileName)).count) file(s)\
        \(result.unchanged > 0
            ? "\n  \(result.unchanged) skipped — outside the change"
            : "")\
        \(result.uncovered > 0
            ? "\n  \(result.uncovered) skipped — no test reaches them"
            : "")
          plan written to \(planURL.path)

          next:
            litmus run --project \(workingCopy.path) \\
                       --plan \(planURL.path) \\
                       --scheme <scheme> --destination <destination>
        """)
    }
}
