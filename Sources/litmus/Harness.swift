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

/// The options both `inject` and `run` need, because both may have to build
/// and run the suite: one to measure coverage, the other to kill mutants.
struct HarnessOptions: ParsableArguments {
    @Option(help: "How to run the tests: xcode or swiftpm.")
    var harness: HarnessKind = .xcode

    @Option(help: "Scheme to build. Required with the xcode harness.")
    var scheme: String?

    @Option(
        parsing: .upToNextOption,
        help: "Simulator UDIDs to spread the work over. One means sequential."
    )
    var simulators: [String] = []

    @Option(help: "Destination to use when no simulators are given.")
    var destination: String?

    @Option(help: "Test processes to run at once. The swiftpm harness supports 1.")
    var workers: Int = 1

    /// The harness to run with, and one lane per worker.
    ///
    /// A simulator is a real lane — a mutant runs on one at a time. A Swift
    /// package has no such thing, so a lane there is just a slot.
    func resolved(for project: URL) throws -> (harness: any TestHarness, lanes: [String]) {
        switch harness {
        case .xcode:
            guard let scheme else {
                throw ValidationError("--scheme is required with the xcode harness")
            }

            let destinations = simulators.map { "platform=iOS Simulator,id=\($0)" }
                .nilIfEmpty ?? [destination].compactMap { $0 }

            guard !destinations.isEmpty else {
                throw ValidationError("pass --simulators or --destination")
            }

            return (
                Xcodebuild(
                    workingDirectory: project,
                    scheme: scheme,
                    derivedDataPath: project.appendingPathComponent("build/litmus")
                ),
                destinations
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
}

extension Array {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}
