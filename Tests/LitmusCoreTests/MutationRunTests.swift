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
            switchOn mutantSwitch: String?,
            timeout: TimeInterval?,
            onlyTesting target: String?
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

    // MARK: - target by target

    /// Test targets, each aimed at some files, with verdicts chosen per
    /// target. Records what ran where, in a batch or a process of its own.
    private final class TargetStub: BatchingHarness, @unchecked Sendable {
        let laneNoun = "lane"
        let targets: [TestedScope.TestTarget]
        /// Keyed by target, then switch name; anything missing survives.
        let kills: [String: Set<String>]
        let redBaselines: Set<String>

        private let lock = NSLock()
        private(set) var batched: [String: [String]] = [:]
        private(set) var separate: [String: [String]] = [:]
        private(set) var prepared: [String] = []

        init(targets: [TestedScope.TestTarget], kills: [String: Set<String>] = [:], redBaselines: Set<String> = []) {
            self.targets = targets
            self.kills = kills
            self.redBaselines = redBaselines
        }

        func build(lane: String) throws -> BuiltTests { BuiltTests() }
        func coverage(lane: String) throws -> Coverage { Coverage(files: [:]) }

        func testedScope(_ built: BuiltTests) -> TestedScope? {
            TestedScope(
                modules: ["Sample"],
                files: Set(targets.flatMap(\.aimedAt)),
                testTargets: targets
            )
        }

        func test(
            _ built: BuiltTests, lane: String, switchOn mutantSwitch: String?,
            timeout: TimeInterval?, onlyTesting target: String?
        ) throws -> TestOutput {
            let target = target ?? "-"
            lock.lock()
            defer { lock.unlock() }

            guard let mutantSwitch else {
                return redBaselines.contains(target) ? MutationRunTests.failing : MutationRunTests.passing
            }
            separate[target, default: []].append(mutantSwitch)
            return kills[target]?.contains(mutantSwitch) == true ? MutationRunTests.failing : MutationRunTests.passing
        }

        func prepareBatch(_ built: BuiltTests, targets: [TestedScope.TestTarget], lane: String) throws -> Batch.Plan {
            lock.lock()
            prepared = targets.map(\.name)
            lock.unlock()
            return Batch.Plan(built: built)
        }

        func runBatch(
            _ plan: Batch.Plan,
            target: String,
            lane: String,
            ids: [String],
            timeouts: Batch.Timeouts,
            onEvent: (Batch.Event) -> Void
        ) throws -> [String: Verdict] {
            lock.lock()
            defer { lock.unlock() }
            batched[target, default: []].append(contentsOf: ids)

            return Dictionary(uniqueKeysWithValues: ids.map { id in
                if id == Batch.baseline {
                    return (id, redBaselines.contains(target) ? .killed : .survived)
                }
                return (id, kills[target]?.contains(id) == true ? .killed : .survived)
            })
        }
    }

    /// A test source that imports Testing, so the target can be batched.
    private final class TestSource {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("litmus-\(UUID().uuidString).swift")

        init(_ text: String = "import Testing\n") throws {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }

        deinit { try? FileManager.default.removeItem(at: url) }
    }

    private func mutant(_ line: Int, in file: String, once: Bool = false) -> Mutant {
        Mutant(
            filePath: file, line: line, column: 1, utf8Offset: line,
            operator: "RelationalOperatorReplacement", description: "d", evaluatedOnce: once
        )
    }

    @Test("gives a value Swift computes once a process of its own")
    func evaluatedOnceLeavesTheBatch() async throws {
        let source = try TestSource()
        let once = mutant(1, in: "/project/A.swift", once: true)
        let others = [mutant(2, in: "/project/A.swift"), mutant(3, in: "/project/A.swift")]
        let harness = TargetStub(targets: [
            .init(name: "ATests", files: [source.url.path], aimedAt: ["/project/A.swift"]),
        ])

        let summary = try await MutationRun(
            configuration: .init(harness: harness, lanes: ["a"])
        )(others + [once])

        #expect(harness.separate["ATests"] == [once.switchName])
        #expect(harness.batched["ATests"] == [Batch.baseline] + others.map(\.switchName))
        #expect(summary.results.count == 3)
    }

    @Test("runs each mutant in the target aimed at its file")
    func routesByTarget() async throws {
        let a = try TestSource(), b = try TestSource()
        let inA = mutant(1, in: "/project/A.swift")
        let inB = mutant(2, in: "/project/B.swift")
        let harness = TargetStub(targets: [
            .init(name: "ATests", files: [a.url.path], aimedAt: ["/project/A.swift"]),
            .init(name: "BTests", files: [b.url.path], aimedAt: ["/project/B.swift"]),
        ])

        _ = try await MutationRun(configuration: .init(harness: harness, lanes: ["a"]))([inA, inB])

        #expect(harness.prepared == ["ATests", "BTests"])
        #expect(harness.batched["ATests"] == [Batch.baseline, inA.switchName])
        #expect(harness.batched["BTests"] == [Batch.baseline, inB.switchName])
    }

    @Test("gives a survivor to the next target that tests the same file, and keeps the kill")
    func secondTargetKills() async throws {
        let a = try TestSource(), b = try TestSource()
        let shared = mutant(1, in: "/project/Shared.swift")
        let harness = TargetStub(
            targets: [
                .init(name: "ATests", files: [a.url.path], aimedAt: ["/project/Shared.swift"]),
                .init(name: "BTests", files: [b.url.path], aimedAt: ["/project/Shared.swift"]),
            ],
            kills: ["BTests": [shared.switchName]]
        )

        let summary = try await MutationRun(configuration: .init(harness: harness, lanes: ["a"]))([shared])

        #expect(summary.killed == 1)
        #expect(harness.batched["BTests"]?.contains(shared.switchName) == true)
    }

    @Test("does not run a caught mutant again in another target")
    func caughtStaysCaught() async throws {
        let a = try TestSource(), b = try TestSource()
        let shared = mutant(1, in: "/project/Shared.swift")
        let harness = TargetStub(
            targets: [
                .init(name: "ATests", files: [a.url.path], aimedAt: ["/project/Shared.swift"]),
                .init(name: "BTests", files: [b.url.path], aimedAt: ["/project/Shared.swift"]),
            ],
            kills: ["ATests": [shared.switchName]]
        )

        let summary = try await MutationRun(configuration: .init(harness: harness, lanes: ["a"]))([shared])

        #expect(summary.killed == 1)
        #expect(harness.batched["BTests"] == nil)
    }

    @Test("passes over a target whose own suite fails, and runs the rest")
    func redTargetSkipped() async throws {
        let a = try TestSource(), b = try TestSource()
        let inA = mutant(1, in: "/project/A.swift")
        let inB = mutant(2, in: "/project/B.swift")
        let harness = TargetStub(
            targets: [
                .init(name: "ATests", files: [a.url.path], aimedAt: ["/project/A.swift"]),
                .init(name: "BTests", files: [b.url.path], aimedAt: ["/project/B.swift"]),
            ],
            kills: ["BTests": [inB.switchName]],
            redBaselines: ["ATests"]
        )

        let summary = try await MutationRun(configuration: .init(harness: harness, lanes: ["a"]))([inA, inB])

        #expect(summary.results.first { $0.mutant == inA }?.verdict == .error)
        #expect(summary.results.first { $0.mutant == inB }?.verdict == .killed)
    }

    @Test("stops when the only target's suite fails")
    func redOnlyTarget() async throws {
        let a = try TestSource()
        let harness = TargetStub(
            targets: [.init(name: "ATests", files: [a.url.path], aimedAt: ["/project/A.swift"])],
            redBaselines: ["ATests"]
        )

        await #expect(throws: MutationRun.Failure.self) {
            try await MutationRun(configuration: .init(harness: harness, lanes: ["a"]))(
                [self.mutant(1, in: "/project/A.swift")]
            )
        }
    }

    @Test("runs an XCTest target one process per mutant, narrowed to that target")
    func xctestTargetIsolated() async throws {
        let a = try TestSource("import XCTest\nfinal class T: XCTestCase {}\n")
        let inA = mutant(1, in: "/project/A.swift")
        let harness = TargetStub(targets: [
            .init(name: "ATests", files: [a.url.path], aimedAt: ["/project/A.swift"]),
        ])

        _ = try await MutationRun(configuration: .init(harness: harness, lanes: ["a"]))([inA])

        #expect(harness.prepared.isEmpty)
        #expect(harness.separate["ATests"] == [inA.switchName])
    }

    @Test("ignores the driver's own XCTestCase when judging a target")
    func driverIsNotXCTest() throws {
        let source = try TestSource("import Testing\n" + Batch.driver)

        let target = TestedScope.TestTarget(name: "ATests", files: [source.url.path])
        #expect(TestedScope.batchIneligibility(of: target) == nil)
    }

    // MARK: - build repair

    /// Fails to build until the named mutants are gone.
    private final class RejectingHarness: TestHarness, @unchecked Sendable {
        let laneNoun = "lane"
        private let lock = NSLock()
        private var rejected: Set<String>
        private(set) var builds = 0

        init(rejecting ids: Set<String>) { rejected = ids }

        func accept(_ ids: [String]) {
            lock.lock(); defer { lock.unlock() }
            rejected.subtract(ids)
        }

        func build(lane: String) throws -> BuiltTests {
            lock.lock(); defer { lock.unlock() }
            builds += 1
            guard rejected.isEmpty else { throw BuildFailure(log: "error: rejected") }
            return BuiltTests()
        }

        func coverage(lane: String) throws -> Coverage { Coverage(files: [:]) }

        func test(
            _ built: BuiltTests, lane: String, switchOn mutantSwitch: String?,
            timeout: TimeInterval?, onlyTesting target: String?
        ) throws -> TestOutput {
            MutationRunTests.passing
        }
    }

    @Test("reports a mutant the compiler rejected as an error and runs the rest")
    func repairsBuild() async throws {
        let mutants = (1...3).map(mutant)
        let bad = mutants[1]
        let harness = RejectingHarness(rejecting: [bad.switchName])

        let summary = try await MutationRun(
            configuration: .init(harness: harness, lanes: ["a"], repair: { _, _ in
                harness.accept([bad.switchName])
                return [bad]
            })
        )(mutants)

        #expect(harness.builds == 2)
        #expect(summary.unviable == 1)
        #expect(summary.survived == 2)
        #expect(summary.results.first { $0.verdict == .unviable }?.mutant == bad)
    }

    @Test("stops when the repair cannot tell which mutant broke the build")
    func unrepairable() async {
        let harness = RejectingHarness(rejecting: ["x"])

        await #expect(throws: BuildFailure.self) {
            try await MutationRun(
                configuration: .init(harness: harness, lanes: ["a"], repair: { _, _ in [] })
            )([mutant(1)])
        }
    }
}
