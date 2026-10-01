import ArgumentParser
import Foundation
import LitmusCore

/// Which harness the run uses.
enum HarnessKind: String, CaseIterable {
    /// Builds a scheme and runs it on a simulator.
    case xcode
    /// Runs the package's own tests on this machine. No simulator, so a mutant
    /// costs the tests rather than a simulator round trip.
    case swiftpm
}

/// Where the tests run. Both are worked out from the project; they are here
/// for when the guess is wrong.
struct DeviceOptions: ParsableArguments {
    @Option(help: "Run only this scheme's tests, instead of every unit test in the project.")
    var scheme: String?

    @Option(help: "An xcodebuild destination to use, instead of a simulator litmus picks.")
    var destination: String?
}

/// How to build and run the suite, and how many mutants at once.
///
/// Whether the project runs on a simulator or with `swift test` is worked
/// out from it: a package that uses UIKit, or is for iOS alone, goes to a
/// simulator.
struct HarnessOptions: ParsableArguments {
    @OptionGroup var device: DeviceOptions

    @Option(help: "How many mutants to run at once: each on a simulator of its own, or for a Swift package, in a copy of its own.")
    var workers: Int = 1

    /// The combinations that cannot be right whatever the project, refused
    /// before anything is copied or built.
    func validate() throws {
        guard workers >= 1 else {
            throw ValidationError("--workers has to be at least 1")
        }
        guard device.destination == nil || workers == 1 else {
            throw ValidationError("--destination names one device; drop --workers")
        }
    }

    func resolved(
        for project: URL,
        writeScheme: Bool = false,
        say: (String) -> Void = { _ in }
    ) throws -> (harness: any TestHarness, lanes: [String]) {
        try Self.resolve(device, workers: workers, for: project, writeScheme: writeScheme, say: say)
    }

    /// The harness to run with, and one lane per worker.
    ///
    /// A simulator is a real lane — a mutant runs on one at a time. A Swift
    /// package has no such thing, so a lane there is just a slot.
    ///
    /// Without `--scheme`, an Xcode project runs every unit test it has,
    /// through a scheme Litmus writes for the purpose. `writeScheme` says
    /// `project` is Litmus's own copy and the scheme may be written into it;
    /// otherwise one already there is used, and nothing is written.
    static func resolve(
        _ device: DeviceOptions,
        workers: Int,
        for project: URL,
        writeScheme: Bool = false,
        say: (String) -> Void = { _ in }
    ) throws -> (harness: any TestHarness, lanes: [String]) {
        switch Discovery.harness(in: project) {
        case .xcode:
            let scheme = try device.scheme ?? {
                if let all = try Discovery.allTestsScheme(in: project, write: writeScheme) {
                    say("every unit test in the project, through a scheme of litmus's own")
                    return all
                }
                let found = try Discovery.scheme(in: project)
                say("scheme \(found)")
                return found
            }()

            let lanes: [String]
            if let destination = device.destination {
                lanes = [destination]
            } else {
                let found = try Discovery.simulators(count: workers)
                if found.count < workers {
                    say("only \(found.count) simulator(s) available, so that is the width")
                }
                lanes = found.map { "platform=iOS Simulator,id=\($0)" }
            }

            return (
                Xcodebuild(
                    workingDirectory: project,
                    scheme: scheme,
                    derivedDataPath: project.appendingPathComponent("build/litmus"),
                    onActivity: { Heartbeat.shared.report($0) }
                ),
                lanes
            )

        case .swiftpm:
            // Each worker past the first runs in a clone of the built
            // package, so none shares another's .build.
            // Whoever named a device expected the tests to run on one.
            guard device.destination == nil, device.scheme == nil else {
                throw ValidationError(
                    "--scheme and --destination are for Xcode projects; this package runs its tests with swift test"
                )
            }

            return (SwiftPackage(workingDirectory: project, workers: workers), SwiftPackage.lanes(workers))
        }
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
