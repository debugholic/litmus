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

    func run() async throws {
        let project = URL(fileURLWithPath: project).standardizedFileURL
        let workingCopy = output.map { URL(fileURLWithPath: $0) }
            ?? project.deletingLastPathComponent()
                .appendingPathComponent(project.lastPathComponent + "_litmus")

        print("copying to \(workingCopy.path)…")

        let result = try ProjectInjection(include: only)(
            project: project,
            workingCopy: workingCopy
        ) { print("  \($0)") }

        guard !result.mutants.isEmpty else {
            throw ValidationError("nothing to mutate"
                + (only.map { " under '\($0)'" } ?? ""))
        }

        let planURL = plan.map { URL(fileURLWithPath: $0) }
            ?? workingCopy.appendingPathComponent("litmus-plan.json")
        try Plan.write(result.mutants, workingCopy: workingCopy, to: planURL)

        print("""

          \(result.mutants.count) mutants across \
        \(Set(result.mutants.map(\.fileName)).count) file(s)
          plan written to \(planURL.path)

          next:
            litmus run --project \(workingCopy.path) \\
                       --plan \(planURL.path) \\
                       --scheme <scheme> --destination <destination>
        """)
    }
}
