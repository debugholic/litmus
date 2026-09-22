import Foundation

/// Runs a Swift package's tests on the host, without Xcode.
///
/// A package that never reaches for UIKit does not need a simulator, and the
/// simulator is what a mutation run actually costs: narrowing the suite with
/// `-only-testing` once cut test time from 24.6s to 0.236s without moving the
/// wall clock at all. The minute per mutant was the round trip, not the tests.
/// Here a mutant costs the tests and nothing else.
public struct SwiftPackage: Sendable, TestHarness {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    public let laneNoun = "process"

    let executable: String
    let workingDirectory: URL

    public init(
        executable: String = "/usr/bin/swift",
        workingDirectory: URL
    ) {
        self.executable = executable
        self.workingDirectory = workingDirectory
    }

    public func build(lane: String) throws -> BuiltTests {
        let (log, status) = try run(arguments: ["build", "--build-tests"])

        guard status == 0 else {
            throw Failure(description: "swift build --build-tests failed:\n\(log)")
        }

        // Nothing to carry: `--skip-build` finds the products by itself.
        return BuiltTests()
    }

    public func test(
        _ built: BuiltTests,
        lane: String,
        switchOn mutantSwitch: String?
    ) throws -> TestOutput {
        var environment: [String: String] = [:]

        // The test process is a direct child here, so the variable goes
        // straight onto it. There is no runner in between to strip a
        // `TEST_RUNNER_` prefix, as there is on a simulator.
        if let mutantSwitch {
            environment[mutantSwitch] = "YES"
        }

        let (log, status) = try run(
            arguments: ["test", "--skip-build"],
            environment: environment
        )

        return TestOutput(log: log, status: status)
    }

    private func run(
        arguments: [String],
        environment: [String: String] = [:]
    ) throws -> (log: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = ProcessInfo.processInfo.environment
            .merging(environment) { _, new in new }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()

        // Read before waiting: a full pipe buffer would otherwise deadlock the
        // child, and a test log easily exceeds it.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (String(data: data, encoding: .utf8) ?? "", process.terminationStatus)
    }
}
