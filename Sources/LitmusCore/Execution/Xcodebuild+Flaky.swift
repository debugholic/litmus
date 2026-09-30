import Foundation

extension Xcodebuild {
    /// Adds the flaky driver to these test targets and rebuilds the tests.
    public func prepareFlaky(targets: [TestedScope.TestTarget], lane: String) async throws -> BuiltTests {
        for target in targets {
            try Batch.appendDriver(to: target, source: FlakyDriver.source, named: FlakyDriver.driverClass)
        }
        return try await build(lane: lane)
    }

    /// Runs the flaky driver in one test target to the end, or until the
    /// process stops, and returns what it wrote.
    ///
    /// No relaunch after a crash: a test that takes the process down is
    /// itself the finding, and the passes after it would run in a process
    /// that is no longer fresh anyway.
    public func runFlaky(
        _ built: BuiltTests,
        target: String,
        lane: String,
        runs: Int,
        pick: [ChangedTests.Span]? = nil,
        launchTimeout: TimeInterval = 20 * 60,
        onPass: (FlakyRun) -> Void = { _ in }
    ) async throws -> FlakyRun {
        guard let xctestrun = built.artifact else {
            throw Failure(description: "no .xctestrun to run")
        }

        let laneData = derivedDataPath
            .appendingPathComponent("lanes")
            .appendingPathComponent(Self.folderName(for: lane))
        let scratch = laneData
            .appendingPathComponent("flaky")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let resultsFile = scratch.appendingPathComponent("results.txt")
        var environment = [
            "TEST_RUNNER_\(FlakyDriver.resultsVariable)": resultsFile.path,
            "TEST_RUNNER_\(FlakyDriver.runsVariable)": String(runs),
        ]
        if let pick {
            let pickFile = scratch.appendingPathComponent("pick.txt")
            try pick.map(\.line).joined(separator: "\n").write(to: pickFile, atomically: true, encoding: .utf8)
            environment["TEST_RUNNER_\(FlakyDriver.pickVariable)"] = pickFile.path
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.currentDirectoryURL = workingDirectory
        process.arguments = [
            "test-without-building",
            "-xctestrun", xctestrun.path,
            "-destination", lane,
            "-derivedDataPath", laneData.path,
            "-resultBundlePath", scratch.appendingPathComponent("result.xcresult").path,
            "-only-testing:\(target)/\(FlakyDriver.driverClass)/\(FlakyDriver.driverTest)",
        ]
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

        // Drained as it comes: a full pipe would stall xcodebuild.
        let log = LogTail()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            log.append(handle.availableData)
        }
        defer { pipe.fileHandleForReading.readabilityHandler = nil }

        let exited = Subprocess.Latch()
        process.terminationHandler = { _ in exited.open() }

        try process.run()
        Subprocess.track(process)
        defer { Subprocess.untrack(process) }

        var report = Batch.Report(url: resultsFile)
        var run = FlakyRun(target: target)
        run.grouped = pick != nil
        let launched = Date()

        func consume() {
            let lines = report.lines()
            if run.launch == nil, !lines.isEmpty { run.launch = Date().timeIntervalSince(launched) }
            for line in lines {
                let ended = line.hasPrefix("END")
                run.read(line)
                if ended { onPass(run) }
            }
        }

        while process.isRunning {
            consume()

            if let pass = run.running {
                // A pass that takes ten times the longest one so far, and at
                // least a minute, is not coming back.
                let limit = max(60, run.longestPass * 10)
                if Date().timeIntervalSince(pass.since) > limit {
                    await Subprocess.stop(process)
                    run.stop = FlakyRun.Stop(phase: pass.phase, index: pass.index, hung: true)
                    break
                }
            } else if run.tests.isEmpty, Date().timeIntervalSince(launched) > launchTimeout {
                await Subprocess.stop(process)
                throw Failure(description: """
                the test runner never started:

                \(Self.errorLines(in: log.text))
                """)
            }

            do {
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                await Subprocess.stop(process, grace: 0)
                throw error
            }
        }

        await exited.wait()
        guard exited.isOpen else { throw CancellationError() }
        consume()

        if !run.finished, run.stop == nil {
            guard let pass = run.running else {
                throw Failure(description: """
                the flaky driver did not run:

                \(Self.errorLines(in: log.text))
                """)
            }
            run.stop = FlakyRun.Stop(phase: pass.phase, index: pass.index, hung: false)
        }
        return run
    }
}
