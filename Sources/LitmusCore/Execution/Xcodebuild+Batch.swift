import Foundation

extension Xcodebuild: BatchingHarness {
    public func prepareBatch(
        _ built: BuiltTests,
        targets: [TestedScope.TestTarget],
        lane: String
    ) async throws -> Batch.Plan {
        for target in targets {
            try Batch.appendDriver(to: target)
        }

        // Incremental: only the test targets changed.
        return Batch.Plan(built: try await build(lane: lane))
    }

    public func runBatch(
        _ plan: Batch.Plan,
        target: String,
        lane: String,
        ids: [String],
        timeouts: Batch.Timeouts,
        onEvent: (Batch.Event) -> Void
    ) async throws -> [String: Verdict] {
        guard let xctestrun = plan.built.artifact else {
            throw Failure(description: "no .xctestrun to run")
        }

        let laneData = derivedDataPath
            .appendingPathComponent("lanes")
            .appendingPathComponent(Self.folderName(for: lane))
        let runner = BatchRunner(
            scratch: laneData,
            start: { environment, folder in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.currentDirectoryURL = workingDirectory
                process.arguments = [
                    "test-without-building",
                    "-xctestrun", xctestrun.path,
                    "-destination", lane,
                    "-derivedDataPath", laneData.path,
                    "-resultBundlePath", folder.appendingPathComponent("result.xcresult").path,
                    "-only-testing:\(target)/\(Batch.driverClass)/\(Batch.driverTest)",
                ]
                // The runner hands the test process what starts with this,
                // without it.
                let prefixed = Dictionary(uniqueKeysWithValues: environment.map { ("TEST_RUNNER_\($0.key)", $0.value) })
                process.environment = ProcessInfo.processInfo.environment.merging(prefixed) { _, new in new }
                return process
            },
            fail: { Failure(description: $0) },
            launchAttempts: Self.launchAttempts,
            relaunchDelay: Self.relaunchDelay
        )
        return try await runner.run(ids: ids, timeouts: timeouts, onEvent: onEvent)
    }

    /// How many launches in a row may run nothing before the batch stops.
    static let launchAttempts = 3
    nonisolated(unsafe) static var relaunchDelay: TimeInterval = 5
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
