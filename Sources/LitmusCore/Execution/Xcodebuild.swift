import Foundation

/// Thin wrapper around the `xcodebuild` actions Litmus relies on.
///
/// Everything here is documented in `man xcodebuild`. Litmus deliberately does
/// not read DerivedData's internal layout, parse build descriptions or rewrite
/// the generated `.xctestrun`; those are private to Xcode and change between
/// releases without notice.
public struct Xcodebuild: Sendable {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    let executable: String
    let workingDirectory: URL

    public init(executable: String = "/usr/bin/xcodebuild", workingDirectory: URL) {
        self.executable = executable
        self.workingDirectory = workingDirectory
    }

    /// Builds the tests once, with every mutant compiled in but switched off.
    ///
    /// Returns the generated `.xctestrun`. Litmus only ever reads this file, so
    /// any number of mutants can run against it at the same time.
    public func buildForTesting(
        scheme: String,
        destination: String,
        derivedDataPath: URL
    ) throws -> URL {
        _ = try run(arguments: [
            "build-for-testing",
            "-scheme", scheme,
            "-destination", destination,
            "-derivedDataPath", derivedDataPath.path,
        ])

        let products = derivedDataPath.appendingPathComponent("Build/Products")
        let found = try FileManager.default
            .contentsOfDirectory(at: products, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "xctestrun" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard let xctestrun = found.first else {
            throw Failure(description: "no .xctestrun under \(products.path)")
        }

        return xctestrun
    }

    /// Runs the already built tests with one mutant switched on.
    ///
    /// `TEST_RUNNER_<VAR>` is how xcodebuild passes a variable into the test
    /// runner process; the prefix is stripped on the way in. Setting the
    /// variable on this process alone would not reach the simulator.
    public func testWithoutBuilding(
        xctestrun: URL,
        destination: String,
        switchOn mutantSwitch: String? = nil,
        onlyTesting: [String] = []
    ) throws -> String {
        var arguments = [
            "test-without-building",
            "-xctestrun", xctestrun.path,
            "-destination", destination,
        ]
        arguments += onlyTesting.flatMap { ["-only-testing:\($0)"] }

        var environment: [String: String] = [:]
        if let mutantSwitch {
            environment["TEST_RUNNER_\(mutantSwitch)"] = "YES"
        }

        return try run(arguments: arguments, environment: environment)
    }

    @discardableResult
    private func run(
        arguments: [String],
        environment: [String: String] = [:]
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()

        // Read before waiting: a full pipe buffer would otherwise deadlock the
        // child, and a test log easily exceeds it.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return String(data: data, encoding: .utf8) ?? ""
    }
}
