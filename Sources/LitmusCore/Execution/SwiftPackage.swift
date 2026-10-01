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
    /// `--build-system native`, where the toolchain still has it.
    ///
    /// Swift 6.4's default build system stops compiling a module's other
    /// files once one fails, so a build with rejected mutants names one file's
    /// worth and the repair takes a build per file. The native one compiles
    /// them all: on Litmus's own source, 17 rejected mutants in 8 files
    /// against 1 in 1. Every call takes it, because `--skip-build` looks for
    /// the products where its own build system put them.
    let buildSystem: [String]
    /// How many mutants run at once, each in a package of its own.
    ///
    /// Two `swift test` processes in one package directory contend over
    /// .build, and the damage was not a slow run but a wrong one: a mutant
    /// came back killed in parallel and survived in three sequential runs.
    /// So each worker past the first runs in a clone of the built working
    /// copy, .build and all, made once the build is done.
    let workers: Int

    public init(
        executable: String = "/usr/bin/swift",
        workingDirectory: URL,
        buildSystem: [String]? = nil,
        workers: Int = 1
    ) {
        self.executable = executable
        self.workingDirectory = workingDirectory
        self.buildSystem = buildSystem ?? Self.nativeBuildSystem(executable: executable)
        self.workers = max(1, workers)
    }

    /// `worker 1`, `worker 2`, …: the names the run gives its lanes.
    public static func lanes(_ workers: Int) -> [String] {
        (1...max(1, workers)).map { "worker \($0)" }
    }

    /// Where a lane's tests run: the working copy for the first, a clone
    /// beside it for each after.
    func directory(for lane: String) -> URL {
        guard let number = Int(lane.split(separator: " ").last ?? ""), number > 1 else {
            return workingDirectory
        }
        return Self.clone(of: workingDirectory, worker: number)
    }

    static func clone(of directory: URL, worker: Int) -> URL {
        directory.deletingLastPathComponent()
            .appendingPathComponent("\(directory.lastPathComponent)-worker\(worker)")
    }

    /// Each worker's clone, made again from the build just done. A clone on
    /// APFS shares the original's blocks, so it takes a moment and next to
    /// no space; elsewhere it is a copy.
    private func cloneForWorkers() async throws {
        guard workers > 1 else { return }
        for worker in 2...workers {
            let clone = Self.clone(of: workingDirectory, worker: worker)
            try? FileManager.default.removeItem(at: clone)
            let (cloned, status) = try await run(
                executable: "/bin/cp", arguments: ["-cR", workingDirectory.path, clone.path]
            )
            if status != 0 {
                try? FileManager.default.removeItem(at: clone)
                let (copied, copyStatus) = try await run(
                    executable: "/bin/cp", arguments: ["-R", workingDirectory.path, clone.path]
                )
                guard copyStatus == 0 else {
                    throw Failure(description: "could not copy the package for worker \(worker):\n\(cloned)\n\(copied)")
                }
            }
        }
    }

    /// Read from `swift build --help`, which lists the build systems it takes.
    static func nativeBuildSystem(executable: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["build", "--help"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return [] }
        let help = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        return help.contains("--build-system") && help.contains("native")
            ? ["--build-system", "native"]
            : []
    }

    public func build(lane: String) async throws -> BuiltTests {
        let (log, status) = try await run(arguments: ["build", "--build-tests"])

        guard status == 0 else {
            throw BuildFailure(log: log)
        }
        try await cloneForWorkers()

        // Nothing to carry: `--skip-build` finds the products by itself.
        return BuiltTests()
    }

    public func test(
        _ built: BuiltTests,
        lane: String,
        switchOn mutantSwitch: String?,
        timeout: TimeInterval?,
        onlyTesting target: String?
    ) async throws -> TestOutput {
        var environment: [String: String] = [:]

        // The test process is a direct child here, so the variable goes
        // straight onto it. There is no runner in between to strip a
        // `TEST_RUNNER_` prefix, as there is on a simulator.
        if let mutantSwitch {
            environment[MutationSwitch.activeVariable] = mutantSwitch
        }

        let output = try await Subprocess.run(
            executable: executable,
            arguments: ["test", "--skip-build"] + buildSystem,
            directory: directory(for: lane),
            environment: environment,
            timeout: timeout
        )

        return TestOutput(log: output.log, status: output.status, timedOut: output.timedOut)
    }

    /// `swift test --enable-code-coverage`, then `llvm-cov` for the counts.
    ///
    /// The counts come from llvm-cov rather than from the JSON SwiftPM leaves
    /// behind: that file gives regions, and turning regions back into lines
    /// means redoing arithmetic llvm-cov has already done. A line wrongly
    /// called uncovered drops a mutant that could have been killed.
    public func coverage(lane: String) async throws -> Coverage {
        let (log, status) = try await run(arguments: ["test", "--enable-code-coverage"])
        guard status == 0 else {
            throw Failure(description: Xcodebuild.suiteFailure(in: log))
        }

        let profile = try await codecovDirectory().appendingPathComponent("default.profdata")
        let bundle = try await testBundle()

        let (lcov, exportStatus) = try await run(
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
    private func codecovDirectory() async throws -> URL {
        let (path, status) = try await run(arguments: ["test", "--show-codecov-path"])
        let trimmed = Self.lastLine(of: path)

        guard status == 0, !trimmed.isEmpty else {
            throw Failure(description: "could not find the coverage directory")
        }

        return URL(fileURLWithPath: trimmed).deletingLastPathComponent()
    }

    private func testBundle() async throws -> URL {
        let (path, status) = try await run(arguments: ["build", "--show-bin-path"])
        let trimmed = Self.lastLine(of: path)

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

    /// The path a `--show-…-path` printed, which is its last line: the
    /// native build system warns that it is deprecated on the lines before.
    static func lastLine(of output: String) -> String {
        output.split(whereSeparator: \.isNewline)
            .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    private func run(
        executable: String? = nil,
        arguments: [String],
        environment: [String: String] = [:]
    ) async throws -> (log: String, status: Int32) {
        let output = try await Subprocess.run(
            executable: executable ?? self.executable,
            arguments: executable == nil ? arguments + buildSystem : arguments,
            directory: workingDirectory,
            environment: environment
        )
        return (output.log, output.status)
    }
}
