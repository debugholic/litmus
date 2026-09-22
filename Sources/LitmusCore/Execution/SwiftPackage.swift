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

    /// `swift test --enable-code-coverage`, then `llvm-cov` for the counts.
    ///
    /// The counts come from llvm-cov rather than from the JSON SwiftPM leaves
    /// behind: that file gives regions, and turning regions back into lines
    /// means redoing arithmetic llvm-cov has already done. A line wrongly
    /// called uncovered drops a mutant that could have been killed.
    public func coverage(lane: String) throws -> Coverage {
        let (log, status) = try run(arguments: ["test", "--enable-code-coverage"])
        guard status == 0 else {
            throw Failure(description: "coverage run failed:\n\(log)")
        }

        let profile = try codecovDirectory().appendingPathComponent("default.profdata")
        let bundle = try testBundle()

        let (lcov, exportStatus) = try run(
            executable: "/usr/bin/xcrun",
            arguments: [
                "llvm-cov", "export", "-format=lcov",
                "-instr-profile", profile.path,
                bundle.path,
            ]
        )

        guard exportStatus == 0 else {
            throw Failure(description: "llvm-cov export failed:\n\(lcov)")
        }

        return Lcov.parse(lcov)
    }

    /// SwiftPM is asked where it put the profile rather than guessed at: the
    /// layout differs between build systems.
    private func codecovDirectory() throws -> URL {
        let (path, status) = try run(arguments: ["test", "--show-codecov-path"])
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)

        guard status == 0, !trimmed.isEmpty else {
            throw Failure(description: "could not find the coverage directory")
        }

        return URL(fileURLWithPath: trimmed).deletingLastPathComponent()
    }

    private func testBundle() throws -> URL {
        let (path, status) = try run(arguments: ["build", "--show-bin-path"])
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)

        guard status == 0, !trimmed.isEmpty else {
            throw Failure(description: "could not find the build directory")
        }

        let products = URL(fileURLWithPath: trimmed)
        let bundles = try FileManager.default
            .contentsOfDirectory(at: products, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "xctest" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard let bundle = bundles.first else {
            throw Failure(description: "no .xctest under \(products.path)")
        }

        let name = bundle.deletingPathExtension().lastPathComponent
        return bundle.appendingPathComponent("Contents/MacOS/\(name)")
    }

    private func run(
        executable: String? = nil,
        arguments: [String],
        environment: [String: String] = [:]
    ) throws -> (log: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable ?? self.executable)
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
