import Foundation

/// Thin wrapper around the `xcodebuild` actions Litmus relies on.
///
/// Everything here is documented in `man xcodebuild`. Litmus deliberately does
/// not read DerivedData's internal layout, parse build descriptions or rewrite
/// the generated `.xctestrun`; those are private to Xcode and change between
/// releases without notice.
public struct Xcodebuild: Sendable, TestHarness {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    public let laneNoun = "simulator"

    let executable: String
    let workingDirectory: URL
    let scheme: String
    let derivedDataPath: URL

    public init(
        executable: String = "/usr/bin/xcodebuild",
        workingDirectory: URL,
        scheme: String,
        derivedDataPath: URL
    ) {
        self.executable = executable
        self.workingDirectory = workingDirectory
        self.scheme = scheme
        self.derivedDataPath = derivedDataPath
    }

    public func build(lane: String) throws -> BuiltTests {
        BuiltTests(
            artifact: try buildForTesting(
                scheme: scheme,
                destination: lane,
                derivedDataPath: derivedDataPath
            )
        )
    }

    public func test(
        _ built: BuiltTests,
        lane: String,
        switchOn mutantSwitch: String?
    ) throws -> TestOutput {
        guard let xctestrun = built.artifact else {
            throw Failure(description: "no .xctestrun to run")
        }

        return try testWithoutBuilding(
            xctestrun: xctestrun,
            destination: lane,
            switchOn: mutantSwitch
        )
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
        let (log, status) = try run(arguments: [
            "build-for-testing",
            "-scheme", scheme,
            "-destination", destination,
            "-derivedDataPath", derivedDataPath.path,
        ])

        // Checked, because a build that failed leaves no .xctestrun behind and
        // the missing file is what used to get reported — with the compiler
        // error that caused it nowhere on screen.
        guard status == 0 else {
            throw Failure(description: """
            the build failed:

            \(Self.errorLines(in: log))
            """)
        }

        let products = derivedDataPath.appendingPathComponent("Build/Products")
        let found = try FileManager.default
            .contentsOfDirectory(at: products, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "xctestrun" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard let xctestrun = found.first else {
            throw Failure(description: """
            the build produced no .xctestrun under \(products.path) — \
            does '\(scheme)' have a test target?
            """)
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
    ) throws -> TestOutput {
        // Without -derivedDataPath, every run gets a DerivedData folder of its
        // own under ~/Library: one overnight run left 427 of them, 1.3 GB.
        // One folder per lane instead, so concurrent lanes do not share one.
        let laneData = derivedDataPath
            .appendingPathComponent("lanes")
            .appendingPathComponent(Self.folderName(for: destination))

        // The result bundle is never read — the verdict comes from the log —
        // so it goes somewhere disposable and is removed after the run.
        let resultBundle = laneData
            .appendingPathComponent("results")
            .appendingPathComponent("\(UUID().uuidString).xcresult")
        defer { try? FileManager.default.removeItem(at: resultBundle) }

        var arguments = [
            "test-without-building",
            "-xctestrun", xctestrun.path,
            "-destination", destination,
            "-derivedDataPath", laneData.path,
            "-resultBundlePath", resultBundle.path,
        ]
        arguments += onlyTesting.flatMap { ["-only-testing:\($0)"] }

        var environment: [String: String] = [:]
        if let mutantSwitch {
            environment["TEST_RUNNER_\(MutationSwitch.activeVariable)"] = mutantSwitch
        }

        let (log, status) = try run(arguments: arguments, environment: environment)

        return TestOutput(log: log, status: status)
    }

    /// `xcodebuild test -enableCodeCoverage`, then `xccov` for the totals.
    ///
    /// Reported per file rather than per line. `xccov` will give line detail,
    /// but only one file per invocation, so the line-level report costs a
    /// process per source file. Whole files with nothing running in them are
    /// where most of the waste is, and they come out of a single call.
    public func coverage(lane: String) throws -> Coverage {
        let bundle = derivedDataPath.appendingPathComponent("litmus-coverage.xcresult")
        // xcodebuild refuses to write over one that is already there.
        try? FileManager.default.removeItem(at: bundle)

        let (log, status) = try run(arguments: [
            "test",
            "-scheme", scheme,
            "-destination", lane,
            "-derivedDataPath", derivedDataPath.path,
            "-enableCodeCoverage", "YES",
            "-resultBundlePath", bundle.path,
        ])

        guard status == 0 else {
            throw Failure(description: Self.suiteFailure(in: log))
        }

        let (report, reportStatus) = try run(
            executable: "/usr/bin/xcrun",
            arguments: ["xccov", "view", "--report", "--json", bundle.path]
        )

        guard reportStatus == 0 else {
            throw Failure(description: "xccov failed:\n\(report)")
        }

        return try Self.parse(report)
    }

    public func testedScope(_ built: BuiltTests) -> TestedScope? {
        guard let xctestrun = built.artifact else { return nil }
        return TestedScope.from(xctestrun: xctestrun, derivedData: derivedDataPath)
    }

    /// A destination as a folder name.
    static func folderName(for destination: String) -> String {
        String(destination.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
    }

    /// Why a coverage run did not finish.
    ///
    /// Almost always the suite itself: mutation testing compares against a
    /// green baseline, so a red one stops the run here rather than at the
    /// baseline gate a few minutes later. The failing test names are the
    /// actionable part, and dumping the whole xcodebuild log buries them.
    static func suiteFailure(in log: String) -> String {
        let lines = log.split(separator: "\n").map(String.init)

        if let start = lines.firstIndex(where: { $0.hasPrefix("Failing tests:") }) {
            let failures = lines[start...]
                .dropFirst()
                .prefix { $0.hasPrefix("\t") || $0.hasPrefix("    ") }
                .map { "  " + $0.trimmingCharacters(in: .whitespaces) }

            return """
            the test suite is failing, so there is no green baseline to \
            measure against:

            \(failures.joined(separator: "\n"))

            Fix those first, or pass --no-coverage to skip this step — the \
            baseline check will stop the run anyway.
            """
        }

        return """
        the coverage run did not finish:

        \(errorLines(in: log))
        """
    }

    /// The part of a build log worth showing.
    ///
    /// xcodebuild's output runs to thousands of lines, and pasting all of it
    /// buries the one line that says what went wrong.
    static func errorLines(in log: String) -> String {
        let errors = log
            .split(separator: "\n")
            .filter { $0.contains("error:") || $0.contains("** BUILD FAILED **") }
            .prefix(20)

        guard !errors.isEmpty else {
            return String(log.split(separator: "\n").suffix(20).joined(separator: "\n"))
        }

        return errors.joined(separator: "\n")
    }

    static func parse(_ report: String) throws -> Coverage {
        guard
            let root = try JSONSerialization.jsonObject(with: Data(report.utf8)) as? [String: Any],
            let targets = root["targets"] as? [[String: Any]]
        else {
            throw Failure(description: "not an xccov report")
        }

        var files: [String: Coverage.File] = [:]

        for target in targets {
            for file in target["files"] as? [[String: Any]] ?? [] {
                guard let path = file["path"] as? String else { continue }

                let covered = file["coveredLines"] as? Int ?? 0

                // Every source file is listed under both the library target and
                // the test target that exercises it. Whichever entry saw
                // something run is the one that settles it.
                if covered > 0 {
                    files[path] = .reached
                } else if files[path] == nil {
                    files[path] = .unreached
                }
            }
        }

        return Coverage(files: files)
    }

    @discardableResult
    private func run(
        executable: String? = nil,
        arguments: [String],
        environment: [String: String] = [:]
    ) throws -> (log: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable ?? self.executable)
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

        return (String(data: data, encoding: .utf8) ?? "", process.terminationStatus)
    }
}
