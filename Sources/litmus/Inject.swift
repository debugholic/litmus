import ArgumentParser
import Foundation
import LitmusCore

struct Inject: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Write the mutants into a copy of the project, and stop there."
    )

    @Option(help: "Project to copy. It is never modified.")
    var project: String = "."

    @Option(help: "Where to put the working copy. Defaults to <project>_litmus.")
    var output: String?

    @OptionGroup var scope: ScopeOptions
    @OptionGroup var harness: HarnessOptions

    @Option(help: "Where to write the plan. Defaults to <working copy>/litmus-plan.json.")
    var plan: String?

    func run() async throws {
        let project = URL(fileURLWithPath: project).standardizedFileURL
        let workingCopy = output.map { URL(fileURLWithPath: $0) }
            ?? project.deletingLastPathComponent()
                .appendingPathComponent(project.lastPathComponent + "_litmus")

        let result = try Injection(
            project: project,
            workingCopy: workingCopy,
            scope: scope,
            harness: harness
        )(verbose: true)

        let planURL = plan.map { URL(fileURLWithPath: $0) }
            ?? workingCopy.appendingPathComponent("litmus-plan.json")
        try Plan.write(result.mutants, workingCopy: workingCopy, to: planURL)

        print("""

          \(Injection.scopeLine(result))
          written to \(workingCopy.path)
          plan at \(planURL.path)

          next:
            litmus run --project \(workingCopy.path) --plan \(planURL.path)
        """)
    }
}
