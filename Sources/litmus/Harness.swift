import ArgumentParser
import Foundation
import LitmusCore

/// Which harness the run uses.
enum HarnessKind: String, ExpressibleByArgument, CaseIterable {
    /// Builds a scheme and runs it on a simulator.
    case xcode
    /// Runs the package's own tests on this machine. No simulator, so a mutant
    /// costs the tests rather than a simulator round trip.
    case swiftpm
}

/// How to build and run the suite.
///
/// Every option here has an answer that can be worked out from the project, so
/// all of them are optional. They exist for the times the guess is wrong or the
/// project is ambiguous, not for every run.
struct HarnessOptions: ParsableArguments {
    @Option(help: "How to run the tests. Worked out from the project by default.")
    var harness: HarnessKind?

    @Option(help: "Scheme to build. Used when the project has more than one.")
    var scheme: String?

    @Option(help: "How many mutants to run at once.")
    var workers: Int = 1

    @Option(
        parsing: .upToNextOption,
        help: "Simulator UDIDs to use, instead of picking them."
    )
    var simulators: [String] = []

    @Option(help: "An xcodebuild destination to use, instead of a simulator.")
    var destination: String?

    /// The harness to run with, and one lane per worker.
    ///
    /// A simulator is a real lane — a mutant runs on one at a time. A Swift
    /// package has no such thing, so a lane there is just a slot.
    func resolved(for project: URL, say: (String) -> Void = { _ in }) throws -> (
        harness: any TestHarness,
        lanes: [String]
    ) {
        guard workers >= 1 else {
            throw ValidationError("--workers has to be at least 1")
        }

        switch harness ?? Discovery.harness(in: project) {
        case .xcode:
            let scheme = try scheme ?? {
                let found = try Discovery.scheme(in: project)
                say("scheme \(found)")
                return found
            }()

            return (
                Xcodebuild(
                    workingDirectory: project,
                    scheme: scheme,
                    derivedDataPath: project.appendingPathComponent("build/litmus")
                ),
                try destinations(say: say)
            )

        case .swiftpm:
            // Two `swift test` processes in one package directory contend over
            // .build, and the damage is not a slow run but a wrong one: the
            // same mutant came back killed in parallel and survived in three
            // sequential runs, and a baseline that had passed a minute earlier
            // failed outright. A score reported too high is worse than no
            // score, so this refuses rather than warns.
            //
            // Running each worker against its own copy of the project would
            // make it sound, and is the way to lift this.
            guard workers == 1 else {
                throw ValidationError(
                    "the swiftpm harness runs one mutant at a time: "
                        + "parallel runs share .build and report wrong verdicts"
                )
            }

            return (SwiftPackage(workingDirectory: project), ["worker 1"])
        }
    }

    private func destinations(say: (String) -> Void) throws -> [String] {
        if !simulators.isEmpty {
            return simulators.map { "platform=iOS Simulator,id=\($0)" }
        }

        if let destination {
            guard workers == 1 else {
                throw ValidationError("--destination names one device; drop --workers or pass --simulators")
            }
            return [destination]
        }

        let found = try Discovery.simulators(count: workers)

        if found.count < workers {
            say("only \(found.count) simulator(s) available, so that is the width")
        }

        return found.map { "platform=iOS Simulator,id=\($0)" }
    }
}

/// Which mutants to write.
struct ScopeOptions: ParsableArguments {
    @Option(help: "Only mutate files whose path contains this text.")
    var only: String?

    @Option(help: "Only mutate lines changed since this git ref.")
    var since: String?

    @Flag(help: "Mutate the whole tree, not only what this branch changed.")
    var all = false

    @Flag(
        inversion: .prefixedNo,
        help: "Skip mutants no test reaches. They survive whatever the code does."
    )
    var coverage = true

    /// The ref to diff against, or nil to take the whole tree.
    ///
    /// Defaulting to the branch's own base is what makes a plain `litmus` fit
    /// inside a review. On the default branch, or outside a repository with a
    /// remote, there is nothing to compare against and the whole tree is the
    /// honest scope.
    func base(for project: URL) -> String? {
        if all { return nil }
        if let since { return since }
        return Discovery.defaultBase(in: project)
    }
}
