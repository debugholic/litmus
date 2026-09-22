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
        abstract: "Run every mutant and report what the tests failed to notice."
    )

    @Option(help: "Project with the mutants already injected.")
    var project: String

    @Option(help: "Mutant list, as written by 'muter mutate-without-running'.")
    var plan: String

    @OptionGroup var harness: HarnessOptions

    @Option(help: "Only run mutants whose path contains this text.")
    var only: String?

    @Option(help: "Report format: plain, json, html or xcode.")
    var format: ReportFormat = .plain

    @Option(help: "Write the report here instead of stdout.")
    var output: String?

    func run() async throws {
        let project = URL(fileURLWithPath: project).standardizedFileURL
        var mutants = try Plan.read(contentsOf: URL(fileURLWithPath: plan))

        if let only {
            mutants = mutants.filter { $0.filePath.contains(only) }
        }

        guard !mutants.isEmpty else {
            throw ValidationError("the plan contains no mutants")
        }

        let (testHarness, lanes) = try harness.resolved(for: project)

        // A mutant listed in the plan but absent from the source would run as a
        // false survivor, so drop it and say so rather than scoring it.
        let check = InjectionCheck()(mutants)
        if !check.missing.isEmpty {
            print("  \(check.missing.count) mutant(s) in the plan were never injected — skipping".yellow)
            for mutant in check.missing.prefix(10) {
                print("    \(mutant.fileName):\(mutant.line)  \(mutant.description)")
            }
            if check.missing.count > 10 {
                print("    … and \(check.missing.count - 10) more")
            }
            for path in check.unreadable {
                print("    could not read \(path)")
            }
            print("")
        }

        mutants = check.injected
        guard !mutants.isEmpty else {
            throw ValidationError("no mutant from the plan is present in the source")
        }

        print("\(mutants.count) mutants, \(lanes.count) \(testHarness.laneNoun)(s)")
        print("  checking the baseline first…\n")

        let run = MutationRun(
            configuration: .init(harness: testHarness, lanes: lanes),
            progress: { Self.report($0) }
        )

        let summary = try await run(mutants)
        let rendered = try Report(summary).rendered(as: format)

        if let output {
            try rendered.write(toFile: output, atomically: true, encoding: .utf8)
            print("\n  report written to \(output)")
        } else {
            print("\n" + rendered)
        }
    }

    private static func report(_ result: MutantResult) {
        let mark: String
        switch result.verdict {
        case .killed: mark = "✔ killed  ".green
        case .survived: mark = "✘ survived".red
        case .error: mark = "– error   ".yellow
        }

        let location = "\(result.mutant.fileName):\(result.mutant.line)"
        print("  \(mark) \(location)  \(result.mutant.description)")
    }
}

private extension MutationRun.Summary {
    func formatted() -> String {
        var lines: [String] = [""]

        if let score {
            lines.append("  Litmus score \(String(format: "%.0f", score))%"
                + "  (killed \(killed) / survived \(survived)"
                + (errored > 0 ? " / error \(errored)" : "")
                + ")")
        } else {
            lines.append("  no mutant produced a verdict")
        }

        let survivors = results.filter { $0.verdict == .survived }
        if !survivors.isEmpty {
            lines.append("")
            lines.append("  survived — nothing failed when this changed:")
            for result in survivors.sorted(by: { $0.mutant.line < $1.mutant.line }) {
                lines.append("    \(result.mutant.fileName):\(result.mutant.line)  \(result.mutant.description)")
            }
        }

        return lines.joined(separator: "\n")
    }
}

extension ReportFormat: ExpressibleByArgument {}
