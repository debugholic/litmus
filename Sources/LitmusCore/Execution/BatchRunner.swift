import Foundation

/// Runs a batch in one test target to the end, relaunching past any mutant
/// that takes the process down: what every harness that batches shares.
///
/// The harnesses differ in how they start the process that runs the driver —
/// `xcodebuild test-without-building` on a simulator, `swift test` on the
/// host — and in the error they report. The rest is the driver's protocol:
/// the batch file in, the report out, the probe, the limits, the relaunches.
struct BatchRunner {
    /// Where each launch keeps its batch and report files.
    let scratch: URL
    /// Starts the process that runs the driver, with these variables set on
    /// the test process.
    let start: (_ environment: [String: String], _ scratch: URL) throws -> Process
    /// The harness's error, for a runner that never came up or never moved.
    let fail: (String) -> Error

    /// How many launches in a row may run nothing before the batch stops.
    let launchAttempts: Int
    let relaunchDelay: TimeInterval

    func run(
        ids: [String],
        timeouts: Batch.Timeouts,
        onEvent: (Batch.Event) -> Void
    ) async throws -> [String: Verdict] {
        var timeouts = timeouts
        var verdicts: [String: Verdict] = [:]
        var remaining = ids

        // Where the driver notes which tests reach which mutants. Kept across
        // relaunches, so a crash after the probe does not probe again.
        var probeDirectory: URL? = scratch.appendingPathComponent("probe-\(UUID().uuidString)")
        if let probeDirectory {
            try FileManager.default.createDirectory(at: probeDirectory, withIntermediateDirectories: true)
        }
        defer { probeDirectory.map { try? FileManager.default.removeItem(at: $0) } }

        var stalls = 0

        while !remaining.isEmpty {
            let outcome = try await launch(
                ids: remaining, probeDirectory: probeDirectory, timeouts: &timeouts, onEvent: onEvent
            )
            verdicts.merge(outcome.verdicts.filter { $0.key != Batch.probe }) { _, new in new }

            // A probe that crashes or hangs is not a mutant's doing. Carry on
            // without it: every mutant runs every test, as before probes.
            if outcome.unfinished?.id == Batch.probe {
                probeDirectory.map { try? FileManager.default.removeItem(at: $0) }
                probeDirectory = nil
                remaining = remaining.filter { verdicts[$0] == nil }
                continue
            }

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
            if remaining.count < before {
                stalls = 0
                continue
            }

            // Nothing ran: the runner did not come up, or went down before
            // the first mutant. That is the machine, not a mutant — one run
            // ended half an hour in on a spawn launchd refused once — so it
            // is tried again before the batch gives up.
            stalls += 1
            guard stalls < launchAttempts else {
                throw fail("the batch made no progress:\n\n\(Xcodebuild.errorLines(in: outcome.log))")
            }
            try await Task.sleep(nanoseconds: UInt64(relaunchDelay * 1_000_000_000))
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
        ids: [String],
        probeDirectory: URL?,
        timeouts: inout Batch.Timeouts,
        onEvent: (Batch.Event) -> Void
    ) async throws -> Launch {
        let folder = scratch
            .appendingPathComponent("batch")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let batchFile = folder.appendingPathComponent("batch.txt")
        let resultsFile = folder.appendingPathComponent("results.txt")
        try ids.joined(separator: "\n").write(to: batchFile, atomically: true, encoding: .utf8)

        var environment = [
            Batch.batchFileVariable: batchFile.path,
            Batch.resultsFileVariable: resultsFile.path,
        ]
        if let probeDirectory {
            environment[Batch.probeDirectoryVariable] = probeDirectory.path
            // Noted from the start, so a value Swift computes once is seen
            // even when the baseline is what first reads it.
            environment[MutationSwitch.probeVariable] = probeDirectory
                .appendingPathComponent(Batch.launchProbe).path
        }
        let process = try start(environment, folder)

        // Drained on its own thread: a full pipe would stall the runner.
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
        var verdicts: [String: Verdict] = [:]
        var current: (id: String, started: Date)?
        var limits: [String: TimeInterval] = [:]
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
                case let .timed(test, seconds):
                    timeouts.tests[test] = seconds
                case let .covered(id, tests):
                    limits[id] = timeouts.mutant(running: tests)
                case .reached, .test, .killedBy, .failedAlone:
                    break
                }
            }
        }

        while process.isRunning {
            consume()

            if let running = current {
                // The probe runs every test once more, one at a time: about a
                // baseline's worth, so it gets the baseline's allowance.
                let limit = running.id == Batch.baseline || running.id == Batch.probe
                    ? timeouts.baseline
                    : limits[running.id] ?? timeouts.mutant
                if Date().timeIntervalSince(running.started) > limit {
                    await Subprocess.stop(process)
                    stopped = true
                    break
                }
            } else if !reported, Date().timeIntervalSince(launched) > timeouts.launch {
                await Subprocess.stop(process)
                throw fail("""
                the test runner never started:

                \(Xcodebuild.errorLines(in: log.text))
                """)
            }

            // Slept as a task, so the lane holds no thread between reads.
            // Cancelled, the runner goes with the lane.
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

        return Launch(
            verdicts: verdicts,
            unfinished: current.map { ($0.id, Date().timeIntervalSince($0.started)) },
            stopped: stopped,
            log: log.text
        )
    }
}
