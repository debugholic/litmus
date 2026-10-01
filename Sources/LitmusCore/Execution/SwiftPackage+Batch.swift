import Foundation

extension SwiftPackage: BatchingHarness {
    /// The test targets and the modules each tests, from the package's own
    /// description: a test target is aimed at the targets it depends on.
    ///
    /// Without it every mutant ran the whole suite in a process of its own;
    /// with it they run in a batch, and only the tests that reach them.
    public func testedScope(_ built: BuiltTests) -> TestedScope? {
        guard let description = describe() else { return nil }
        return Self.scope(from: description, root: workingDirectory)
    }

    public func coverageScope() -> TestedScope? { nil }

    /// `swift package describe --type json`.
    private func describe() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["package", "describe", "--type", "json"]
        process.currentDirectoryURL = workingDirectory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    static func scope(from description: Data, root: URL) -> TestedScope? {
        guard
            let object = try? JSONSerialization.jsonObject(with: description) as? [String: Any],
            let targets = object["targets"] as? [[String: Any]]
        else { return nil }

        struct Target {
            let name: String
            let isTest: Bool
            let files: [String]
            let dependencies: [String]
        }
        let all: [Target] = targets.compactMap { target in
            guard let name = target["name"] as? String, let path = target["path"] as? String else { return nil }
            let folder = root.appendingPathComponent(path)
            return Target(
                name: name,
                isTest: target["type"] as? String == "test",
                files: (target["sources"] as? [String] ?? []).map { folder.appendingPathComponent($0).path },
                dependencies: target["target_dependencies"] as? [String] ?? []
            )
        }
        let modules = all.filter { !$0.isTest }
        guard !modules.isEmpty else { return nil }
        let byName = Dictionary(uniqueKeysWithValues: modules.map { ($0.name, $0) })

        var moduleOf: [String: String] = [:]
        for module in modules {
            for file in module.files { moduleOf[file] = module.name }
        }

        return TestedScope(
            modules: modules.map(\.name),
            files: Set(modules.flatMap(\.files)),
            testTargets: all.filter(\.isTest).map { test in
                TestedScope.TestTarget(
                    name: test.name,
                    files: test.files,
                    aimedAt: Set(test.dependencies.compactMap { byName[$0] }.flatMap(\.files))
                )
            },
            moduleOf: moduleOf
        )
    }

    /// Adds the driver to these test targets, then builds again, which
    /// clones the package for every worker with the driver in it.
    public func prepareBatch(
        _ built: BuiltTests,
        targets: [TestedScope.TestTarget],
        lane: String
    ) async throws -> Batch.Plan {
        for target in targets {
            try Batch.appendDriver(to: target)
        }
        return Batch.Plan(built: try await build(lane: lane))
    }

    /// `swift test`, filtered to the driver, in the lane's own copy of the
    /// package. The variables go straight onto the test process: there is
    /// no runner in between to take a prefix off.
    public func runBatch(
        _ plan: Batch.Plan,
        target: String,
        lane: String,
        ids: [String],
        timeouts: Batch.Timeouts,
        onEvent: (Batch.Event) -> Void
    ) async throws -> [String: Verdict] {
        let directory = directory(for: lane)
        let runner = BatchRunner(
            scratch: directory.appendingPathComponent(".build/litmus"),
            start: { environment, _ in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.currentDirectoryURL = directory
                process.arguments = ["test", "--skip-build"] + buildSystem + [
                    "--filter", "^\(NSRegularExpression.escapedPattern(for: target))\\.\(Batch.driverClass)/\(Batch.driverTest)$",
                ]
                process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
                return process
            },
            fail: { Failure(description: $0) },
            launchAttempts: Xcodebuild.launchAttempts,
            relaunchDelay: Xcodebuild.relaunchDelay
        )
        return try await runner.run(ids: ids, timeouts: timeouts, onEvent: onEvent)
    }
}
