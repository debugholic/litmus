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

    /// Replaced with the tag when a release is built.
    ///
    /// A build from source says "dev" rather than claiming a version it is
    /// not. The release workflow rewrites this line and checks that it took,
    /// so a rename here cannot quietly ship an unstamped binary.
    static let version = "dev"

    static let configuration = CommandConfiguration(
        commandName: "litmus",
        abstract: "Mutation testing for Swift.",
        version: Litmus.version,
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

        let working: URL
        let mutants: [Mutant]

        do {
            (working, mutants) = try prepared(project)
        } catch let nothing as NothingToMutate {
            // Not a failure and not a misuse: printing usage here would say the
            // command was typed wrong, and exiting non-zero would turn a
            // documentation-only branch into a red pipeline.
            print("\(nothing.reason).")
            print("Pass --all to mutate the whole tree.")
            return
        }

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

        // Quiet here: whatever it had to work out was already said and printed
        // while the mutants were being written.
        let (testHarness, lanes) = try harness.resolved(for: working)

        print("\n\(check.injected.count) mutants, \(lanes.count) at a time\n")

        let summary = try await MutationRun(
            configuration: .init(harness: testHarness, lanes: lanes),
            progress: { Self.show($0) }
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

        // Beside the project, not in /tmp: the two are usually on different
        // volumes, and a copy that crosses one cannot share bytes with the
        // original. A dependency store can be gigabytes.
        let workingCopy = project.deletingLastPathComponent()
            .appendingPathComponent(".litmus-\(project.lastPathComponent)")

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

    /// Says what is happening while it happens.
    ///
    /// A build is minutes and a single mutant can be more than that, all of it
    /// with nothing on screen. Silence on a terminal reads as a hang, and the
    /// honest thing to do is to name the step before waiting on it.
    /// One at a time: the steps below never overlap, and a mutant's own line
    /// is printed the moment it starts.
    private static let heartbeat = Heartbeat()

    private static func show(_ step: MutationRun.Step) {
        switch step {
        case .building:
            print("  building once, with every mutant switched off…")
            heartbeat.begin()

        case .checkingBaseline:
            heartbeat.end()
            print("  running the suite untouched, to check it passes…")
            heartbeat.begin()

        case let .baselinePassed(duration):
            heartbeat.end()
            print("  baseline passed in \(time(duration))\n")

        case let .started(mutant):
            print("  → \(location(mutant))  \(mutant.description)")
            heartbeat.begin()

        case let .finished(result, done, total):
            heartbeat.end()
            let mark: String
            switch result.verdict {
            case .killed: mark = "✔ killed  ".green
            case .survived: mark = "✘ survived".red
            case .error: mark = "– error   ".yellow
            }

            let counter = "[\(done)/\(total)]".dim
            print("  \(mark) \(counter) \(location(result.mutant))  "
                + "\(result.mutant.description)  \(time(result.duration).dim)")
        }
    }

    private static func location(_ mutant: Mutant) -> String {
        "\(mutant.fileName):\(mutant.line)"
    }

    private static func time(_ seconds: TimeInterval) -> String {
        Heartbeat.format(seconds)
    }
}

extension ReportFormat: ExpressibleByArgument {}
