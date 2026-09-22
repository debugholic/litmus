import ArgumentParser
import Foundation
import LitmusCore
import Rainbow

@main
struct Litmus: AsyncParsableCommand {
    init() {
        // A run takes minutes, and stdout is block-buffered when it is not a
        // terminal: piped to a file or a CI log, every line of progress would
        // arrive at the end, after the part worth watching is over.
        setvbuf(stdout, nil, _IOLBF, 0)
    }

    static let configuration = CommandConfiguration(
        commandName: "litmus",
        abstract: "Mutation testing for Swift.",
        subcommands: [Inject.self, Run.self],
        defaultSubcommand: Run.self
    )
}

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Change the code on purpose and report what the tests did not notice."
    )

    @Option(help: "Project to test. It is never modified.")
    var project: String = "."

    @Option(help: "An already injected plan, from 'litmus inject'.")
    var plan: String?

    @OptionGroup var scope: ScopeOptions
    @OptionGroup var harness: HarnessOptions

    @Option(help: "Report format: plain, json, html or xcode.")
    var format: ReportFormat = .plain

    @Option(help: "Write the report here instead of stdout.")
    var output: String?

    func run() async throws {
        let project = URL(fileURLWithPath: project).standardizedFileURL
        let (working, mutants) = try prepared(project)

        // A mutant listed in the plan but absent from the source would run as a
        // false survivor, so drop it and say so rather than scoring it.
        let check = InjectionCheck()(mutants)
        if !check.missing.isEmpty {
            print("  \(check.missing.count) mutant(s) were never injected — skipping".yellow)
            for mutant in check.missing.prefix(10) {
                print("    \(mutant.fileName):\(mutant.line)  \(mutant.description)")
            }
            if check.missing.count > 10 {
                print("    … and \(check.missing.count - 10) more")
            }
            for path in check.unreadable {
                print("    could not read \(path)")
            }
        }

        guard !check.injected.isEmpty else {
            throw ValidationError("no mutant from the plan is present in the source")
        }

        let (testHarness, lanes) = try harness.resolved(for: working) { print("  \($0)") }

        print("\(check.injected.count) mutants, \(lanes.count) at a time")
        print("  checking the baseline first…\n")

        let summary = try await MutationRun(
            configuration: .init(harness: testHarness, lanes: lanes),
            progress: { Self.report($0) }
        )(check.injected)

        let rendered = try Report(summary).rendered(as: format)

        if let output {
            try rendered.write(toFile: output, atomically: true, encoding: .utf8)
            print("\n  report written to \(output)")
        } else {
            print("\n" + rendered)
        }
    }

    /// The copy to run in, and what to run in it.
    ///
    /// Injecting is part of a run, not a step before it. Passing `--plan` says
    /// the work was already done — by `litmus inject`, for a copy worth looking
    /// at — and this runs that instead.
    private func prepared(_ project: URL) throws -> (working: URL, mutants: [Mutant]) {
        if let plan {
            return (project, try Plan.read(contentsOf: URL(fileURLWithPath: plan)))
        }

        let workingCopy = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("litmus-\(project.lastPathComponent)")

        let result = try Injection(
            project: project,
            workingCopy: workingCopy,
            scope: scope,
            harness: harness
        )(verbose: false)

        // Said before the run, not only in the report: a narrowed run that
        // scores well is not a clean bill of health for the project, and the
        // number alone does not say so.
        print(Injection.scopeLine(result))

        return (workingCopy, result.mutants)
    }

    private static func report(_ result: MutantResult) {
        let mark: String
        switch result.verdict {
        case .killed: mark = "✔ killed  ".green
        case .survived: mark = "✘ survived".red
        case .error: mark = "– error   ".yellow
        }

        print("  \(mark) \(result.mutant.fileName):\(result.mutant.line)  \(result.mutant.description)")
    }
}

extension ReportFormat: ExpressibleByArgument {}
