import Foundation

extension Xcodebuild: BatchingHarness {
    public func prepareBatch(_ built: BuiltTests, scope: TestedScope, lane: String) throws -> Batch.Plan? {
        guard let target = scope.batchTarget else { return nil }

        try Batch.appendDriver(to: target)

        // Incremental: only the test target changed.
        return Batch.Plan(built: try build(lane: lane), testTarget: target.name)
    }

    public func runBatch(
        _ plan: Batch.Plan,
        lane: String,
        ids: [String],
        timeouts: Batch.Timeouts,
        onEvent: (Batch.Event) -> Void
    ) throws -> [String: Verdict] {
        guard let xctestrun = plan.built.artifact else {
            throw Failure(description: "no .xctestrun to run")
        }

        var timeouts = timeouts
        var verdicts: [String: Verdict] = [:]
        var remaining = ids

        while !remaining.isEmpty {
            let outcome = try launch(
                plan, xctestrun: xctestrun, lane: lane, ids: remaining,
                timeouts: &timeouts, onEvent: onEvent
            )
            verdicts.merge(outcome.verdicts) { _, new in new }

            // The mutant that was running when the process died, or was
            // stopped for taking too long, took the process with it. A crash
            // or a hang: either way the suite did not pass with it on.
            if let unfinished = outcome.unfinished {
                let verdict: Verdict = outcome.stopped ? .timedOut : .killed
                verdicts[unfinished.id] = verdict
                onEvent(.finished(unfinished.id, verdict, unfinished.elapsed))
            }

            // A red baseline ends the batch. Nothing after it means anything.
            if let base = verdicts[Batch.baseline], base != .survived { break }

            let before = remaining.count
            remaining = remaining.filter { verdicts[$0] == nil }

            guard remaining.count < before else {
                throw Failure(description: "the batch made no progress:\n\n\(Self.errorLines(in: outcome.log))")
            }
        }

        return verdicts
    }

    private struct Launch {
        var verdicts: [String: Verdict]
        var unfinished: (id: String, elapsed: TimeInterval)?
        /// Litmus stopped it for running too long, rather than it crashing.
        var stopped: Bool
        var log: String
    }

    private func launch(
        _ plan: Batch.Plan,
        xctestrun: URL,
        lane: String,
        ids: [String],
        timeouts: inout Batch.Timeouts,
        onEvent: (Batch.Event) -> Void
    ) throws -> Launch {
        let laneData = derivedDataPath
            .appendingPathComponent("lanes")
            .appendingPathComponent(Self.folderName(for: lane))
        let scratch = laneData
            .appendingPathComponent("batch")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let batchFile = scratch.appendingPathComponent("batch.txt")
        let resultsFile = scratch.appendingPathComponent("results.txt")
        try ids.joined(separator: "\n").write(to: batchFile, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.currentDirectoryURL = workingDirectory
        process.arguments = [
            "test-without-building",
            "-xctestrun", xctestrun.path,
            "-destination", lane,
            "-derivedDataPath", laneData.path,
            "-resultBundlePath", scratch.appendingPathComponent("result.xcresult").path,
            "-only-testing:\(plan.testTarget)/\(Batch.driverClass)/\(Batch.driverTest)",
        ]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "TEST_RUNNER_\(Batch.batchFileVariable)": batchFile.path,
            "TEST_RUNNER_\(Batch.resultsFileVariable)": resultsFile.path,
        ]) { _, new in new }

        // Drained on its own thread: a full pipe would stall xcodebuild.
        let log = LogTail()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            log.append(handle.availableData)
        }
        defer { pipe.fileHandleForReading.readabilityHandler = nil }

        try process.run()

        var report = Batch.Report(url: resultsFile)
        var verdicts: [String: Verdict] = [:]
        var current: (id: String, started: Date)?
        var reported = false
        var stopped = false
        let launched = Date()

        func consume() {
            for event in report.read() {
                onEvent(event)
                reported = true

                switch event {
                case let .started(id):
                    current = (id, Date())
                case let .finished(id, verdict, duration):
                    verdicts[id] = verdict
                    current = nil
                    if id == Batch.baseline, verdict == .survived {
                        timeouts.learn(baseline: duration)
                    }
                }
            }
        }

        while process.isRunning {
            consume()

            if let running = current {
                let limit = running.id == Batch.baseline ? timeouts.baseline : timeouts.mutant
                if Date().timeIntervalSince(running.started) > limit {
                    Subprocess.stop(process)
                    stopped = true
                    break
                }
            } else if !reported, Date().timeIntervalSince(launched) > timeouts.launch {
                Subprocess.stop(process)
                throw Failure(description: """
                the test runner never started:

                \(Self.errorLines(in: log.text))
                """)
            }

            Thread.sleep(forTimeInterval: 0.5)
        }

        process.waitUntilExit()
        consume()

        return Launch(
            verdicts: verdicts,
            unfinished: current.map { ($0.id, Date().timeIntervalSince($0.started)) },
            stopped: stopped,
            log: log.text
        )
    }
}

/// The last part of a log, kept while it is being written.
final class LogTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit = 256 * 1024

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }

        data.append(chunk)
        if data.count > limit {
            data = data.suffix(limit)
        }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
