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

    @Flag(help: "Give every mutant a fresh process instead of running them in one.")
    var isolate = false

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
        // Litmus's own copy may take its scheme; a copy handed in with
        // --plan keeps whatever it has.
        let (testHarness, lanes) = try harness.resolved(for: working, writeScheme: plan == nil)

        print("\n\(check.injected.count) mutants, \(lanes.count) at a time\n")

        // A plan brings its own copy, with no original beside it to rewrite
        // a rejected file from.
        let repair = plan == nil ? BuildRepair(project: project, workingCopy: working) : nil
        let allTests = (testHarness as? Xcodebuild)?.scheme == AllTestsScheme.name

        let summary = try await MutationRun(
            configuration: .init(
                harness: testHarness,
                lanes: lanes,
                batching: !isolate,
                repair: repair.map { repair in
                    Self.repairing(with: repair, allTests: allTests, in: working)
                }
            ),
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

    /// Takes out what a failed build names: the mutants the compiler
    /// rejected, or failing that, with Litmus's scheme of every test, a test
    /// target that does not build on its own.
    private static func repairing(
        with repair: BuildRepair,
        allTests: Bool,
        in working: URL
    ) -> @Sendable (String, [Mutant]) throws -> [Mutant]? {
        { log, mutants in
            let pulled = try repair(log: log, mutants: mutants)
            if !pulled.isEmpty { return pulled }

            guard allTests else { return nil }
            let dropped = try AllTestsScheme.leaveOut(failedIn: log, in: working)
            guard !dropped.isEmpty else { return nil }

            print("  leaving out \(dropped.joined(separator: ", ")) — it does not build".yellow)
            return []
        }
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

        case let .unviable(mutants):
            heartbeat.end()
            print("  the compiler rejected \(mutants.count) mutant(s) — taking them out and building again:".yellow)
            for mutant in mutants.prefix(10) {
                print("    \(location(mutant))  \(mutant.description)")
            }
            if mutants.count > 10 {
                print("    … and \(mutants.count - 10) more")
            }
            heartbeat.begin()

        case let .scoped(modules, kept, dropped):
            heartbeat.end()
            print("  these tests are aimed at \(modules.joined(separator: ", "))")
            if dropped > 0 {
                print("  skipping \(dropped) mutant(s) in code they do not test — \(kept) left")
            }
            if kept == 0 {
                print("  nothing left to run: none of the mutants are in code these tests are aimed at")
            }

        case let .preparingBatch(targets):
            heartbeat.end()
            print("  adding the in-process driver to \(targets) test target(s) and rebuilding…")
            heartbeat.begin()

        case let .target(name, mutants, isolated):
            heartbeat.end()
            let how = isolated.map { "one process each — \($0)" } ?? "in one process"
            print("\n  \(name): \(mutants) mutant(s), \(how)")

        case let .targetSkipped(name, reason):
            heartbeat.end()
            print("  skipping \(name): \(reason)".yellow)

        case let .oneProcessPerMutant(reason):
            heartbeat.end()
            print("  one process per mutant: \(reason)")

        case .checkingBaseline:
            heartbeat.end()
            print("  running the suite untouched, to check it passes…")
            heartbeat.begin()

        case let .baselinePassed(duration):
            heartbeat.end()
            print("  baseline passed in \(time(duration))\n")

        case let .evaluatedOnce(count):
            print("\n  \(count) mutant(s) in a global or static value, each in a process of its own:")

        case let .started(mutant):
            print("  → \(location(mutant))  \(mutant.description)")
            heartbeat.begin()

        case let .finished(result, done, total):
            heartbeat.end()
            let mark: String
            switch result.verdict {
            case .killed: mark = "✔ killed  ".green
            case .survived: mark = "✘ survived".red
            case .timedOut: mark = "✔ timeout ".green
            case .unviable: mark = "– unviable".yellow
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
