import ArgumentParser
import Foundation
import LitmusCore

struct Inject: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Write the mutants into a copy of the project, and stop there."
    )

    @Option(help: "Project to copy. It is never modified.")
    var project: String = "."

    @Option(help: "Where to put the working copy. Defaults to ~/Library/Caches/litmus/<project>-<id>.")
    var output: String?

    @OptionGroup var scope: ScopeOptions
    @OptionGroup var harness: HarnessOptions

    @Option(help: "Where to write the plan. Defaults to <working copy>/litmus-plan.json.")
    var plan: String?

    func run() async throws {
        let project = URL(fileURLWithPath: project).standardizedFileURL
        let workingCopy = output.map { URL(fileURLWithPath: $0) }
            ?? WorkingCopy.location(for: project)

        let result: ProjectInjection.Result
        do {
            result = try Injection(
                project: project,
                workingCopy: workingCopy,
                scope: scope,
                harness: harness
            )(verbose: true)
        } catch let nothing as NothingToMutate {
            print("\(nothing.reason).")
            print("Pass --all to mutate the whole tree.")
            return
        }

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
