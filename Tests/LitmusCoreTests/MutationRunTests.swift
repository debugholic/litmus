import Foundation
import Testing

@testable import LitmusCore

/// Driving a run without building or launching anything.
///
/// `TestHarness` exists so the schedule can be tested apart from xcodebuild,
/// and this is the part a mutation run could not reach: every branch of the
/// baseline gate and the worker loop survived.
@Suite("Mutation run")
struct MutationRunTests {
    // MARK: - doubles

    private static let passing = TestOutput(
        log: "Test run with 10 tests in 1 suites passed after 0.1 seconds.",
        status: 0
    )

    private static let failing = TestOutput(
        log: "Test run with 10 tests in 1 suites failed after 0.1 seconds.",
        status: 1
    )

    private static let unbuildable = TestOutput(
        log: "Testing cancelled because the build failed.",
        status: 65
    )

    /// Records what ran where, from several tasks at once.
    private final class Ledger: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var switchesRun: [String] = []
        private(set) var lanesUsed: [String] = []
        private(set) var peakConcurrency = 0
        private(set) var doubleBookedLane = false

        private var busyLanes: Set<String> = []

        func begin(lane: String, mutantSwitch: String?) {
            lock.lock()
            defer { lock.unlock() }

            if let mutantSwitch {
                switchesRun.append(mutantSwitch)
                lanesUsed.append(lane)
            }

            // A lane is one simulator. Two mutants on it at once would mean the
            // scheduler handed out a lane that was still busy.
            if busyLanes.contains(lane) { doubleBookedLane = true }
            busyLanes.insert(lane)
            peakConcurrency = max(peakConcurrency, busyLanes.count)
        }

        func end(lane: String) {
            lock.lock()
            defer { lock.unlock() }
            busyLanes.remove(lane)
        }

        /// Blocks until `count` lanes are busy at once, or gives up.
        ///
        /// Sleeping a fixed time instead made this a race: on a loaded machine
        /// three tasks that are meant to overlap simply did not, and the test
        /// failed for a reason that had nothing to do with the scheduler.
        /// Giving up rather than failing here keeps the last, partial batch
        /// from hanging the run.
        func awaitSaturation(_ count: Int, within seconds: TimeInterval) {
            let deadline = Date().addingTimeInterval(seconds)

            while Date() < deadline {
                lock.lock()
                let reached = busyLanes.count >= count
                lock.unlock()

                if reached { return }
                usleep(1_000)
            }
        }
    }

    private struct StubHarness: TestHarness {
        let laneNoun = "lane"
        let ledger: Ledger
        let baseline: TestOutput
        /// Keyed by switch name; anything missing passes, so the mutant survives.
        let outcomes: [String: TestOutput]
        let duration: TimeInterval
        /// Lanes to wait for before returning, so overlap is not left to chance.
        var saturate: Int = 0

        func build(lane: String) throws -> BuiltTests { BuiltTests() }

        func coverage(lane: String) throws -> Coverage { Coverage(files: [:]) }

        func test(
            _ built: BuiltTests,
            lane: String,
            switchOn mutantSwitch: String?
        ) throws -> TestOutput {
            ledger.begin(lane: lane, mutantSwitch: mutantSwitch)
            defer { ledger.end(lane: lane) }

            if saturate > 0 { ledger.awaitSaturation(saturate, within: 5) }
            if duration > 0 { Thread.sleep(forTimeInterval: duration) }

            guard let mutantSwitch else { return baseline }
            return outcomes[mutantSwitch] ?? Self.survives
        }

        static let survives = MutationRunTests.passing
    }

    private func mutant(_ line: Int) -> Mutant {
        Mutant(
            filePath: "/project/Sample.swift",
            line: line,
            column: 1,
            utf8Offset: line * 10,
            operator: "ChangeLogicalConnector",
            description: "changed && to ||"
        )
    }

    private func run(
        _ mutants: [Mutant],
        lanes: [String] = ["a"],
        baseline: TestOutput = passing,
        outcomes: [String: TestOutput] = [:],
        duration: TimeInterval = 0,
        saturate: Int = 0,
        ledger: Ledger = Ledger()
    ) async throws -> MutationRun.Summary {
        try await MutationRun(
            configuration: .init(
                harness: StubHarness(
                    ledger: ledger,
                    baseline: baseline,
                    outcomes: outcomes,
                    duration: duration,
                    saturate: saturate
                ),
                lanes: lanes
            )
        )(mutants)
    }

    // MARK: - the baseline gate

    /// Mutation testing compares against a green baseline. If the suite was
    /// already failing, every mutant looks killed and the score is noise.
    @Test("refuses to run when the suite already fails")
    func redBaseline() async {
        await #expect(throws: MutationRun.Failure.self) {
            try await run([mutant(1)], baseline: Self.failing)
        }
    }

    @Test("refuses to run when the baseline could not run at all")
    func unusableBaseline() async {
        await #expect(throws: MutationRun.Failure.self) {
            try await run([mutant(1)], baseline: Self.unbuildable)
        }
    }

    @Test("runs when the baseline passes")
    func greenBaseline() async throws {
        let summary = try await run([mutant(1)])

        #expect(summary.results.count == 1)
    }

    // MARK: - verdicts

    @Test("runs every mutant exactly once")
    func runsEachMutant() async throws {
        let ledger = Ledger()
        let mutants = (1...6).map(mutant)

        _ = try await run(mutants, lanes: ["a", "b", "c"], ledger: ledger)

        #expect(Set(ledger.switchesRun) == Set(mutants.map(\.switchName)))
        #expect(ledger.switchesRun.count == 6)
    }

    @Test("scores killed over killed plus survived, leaving errors out")
    func score() async throws {
        let mutants = (1...4).map(mutant)
        let summary = try await run(mutants, outcomes: [
            mutants[0].switchName: Self.failing,
            mutants[1].switchName: Self.failing,
            mutants[2].switchName: Self.passing,
            mutants[3].switchName: Self.unbuildable,
        ])

        #expect(summary.killed == 2)
        #expect(summary.survived == 1)
        #expect(summary.errored == 1)

        // Two of the three that produced a verdict. Compared with a tolerance
        // because the score is computed as a ratio and 2/3 has no exact double.
        let score = try #require(summary.score)
        #expect(abs(score - 200.0 / 3) < 0.000_1)
    }

    // MARK: - the worker loop

    @Test("keeps one mutant in flight per lane, and no more")
    func concurrency() async throws {
        let ledger = Ledger()

        _ = try await run(
            (1...9).map(mutant),
            lanes: ["a", "b", "c"],
            saturate: 3,
            ledger: ledger
        )

        #expect(ledger.peakConcurrency == 3)
        #expect(!ledger.doubleBookedLane)
    }

    /// The scheduler used to pick the next lane from a counter rather than from
    /// the task that had just finished, which could stack two mutants on one
    /// simulator while another sat idle.
    @Test("never starts a mutant on a lane that is still busy")
    func laneReuse() async throws {
        let ledger = Ledger()

        _ = try await run(
            (1...12).map(mutant),
            lanes: ["a", "b"],
            saturate: 2,
            ledger: ledger
        )

        #expect(!ledger.doubleBookedLane)
        #expect(Set(ledger.lanesUsed) == ["a", "b"])
    }

    @Test("runs everything on the one lane it was given")
    func singleLane() async throws {
        let ledger = Ledger()

        _ = try await run((1...4).map(mutant), lanes: ["only"], ledger: ledger)

        #expect(ledger.lanesUsed == ["only", "only", "only", "only"])
        #expect(ledger.peakConcurrency == 1)
    }

    @Test("does nothing when the plan is empty")
    func noMutants() async throws {
        let summary = try await run([])

        #expect(summary.results.isEmpty)
        #expect(summary.score == nil)
    }
}
