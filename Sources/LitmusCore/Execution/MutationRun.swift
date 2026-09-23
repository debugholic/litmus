import Foundation

/// Drives one mutation testing run: build once, then flip mutants on one at a time.
public struct MutationRun: Sendable {
    public struct Configuration: Sendable {
        /// How the project's tests get built and run.
        public let harness: any TestHarness
        /// One lane per worker: a simulator for xcodebuild, a plain slot for a
        /// Swift package. One entry means sequential.
        public let lanes: [String]
        /// Whether to run many mutants in one test process when the tests
        /// allow it. Off means a fresh process for every mutant.
        public let batching: Bool
        /// Takes the mutants a failed build names out of the source and
        /// returns them, or none when it cannot tell which. Without it, a
        /// build that fails ends the run.
        public let repair: (@Sendable (_ log: String, _ mutants: [Mutant]) throws -> [Mutant])?

        public init(
            harness: any TestHarness,
            lanes: [String],
            batching: Bool = true,
            repair: (@Sendable (_ log: String, _ mutants: [Mutant]) throws -> [Mutant])? = nil
        ) {
            self.harness = harness
            self.lanes = lanes
            self.batching = batching
            self.repair = repair
        }
    }

    public enum Failure: Error, CustomStringConvertible {
        /// The suite does not pass with every mutant switched off.
        ///
        /// Mutation testing compares against a green baseline: a mutant is
        /// "killed" because the suite went from passing to failing. If it was
        /// already failing, every mutant looks killed and the score is noise.
        case baselineNotGreen(Verdict)

        public var description: String {
            switch self {
            case .baselineNotGreen(.killed):
                return "the test suite fails before any mutant is applied"
            case .baselineNotGreen(.error):
                return "the test suite could not run before any mutant is applied"
            case .baselineNotGreen:
                return "the baseline run did not pass"
            }
        }
    }

    public struct Summary: Sendable {
        public let results: [MutantResult]
        public let duration: TimeInterval

        public var killed: Int { results.count { $0.verdict == .killed } }
        public var survived: Int { results.count { $0.verdict == .survived } }
        public var errored: Int { results.count { $0.verdict == .error } }

        /// Killed over everything that actually produced a verdict.
        ///
        /// Mutants that failed to build are excluded rather than counted as
        /// killed; folding them in would report a suite as stronger than it is.
        public var score: Double? {
            let scored = killed + survived
            guard scored > 0 else { return nil }
            return Double(killed) / Double(scored) * 100
        }
    }

    /// What a run is doing, as it does it.
    ///
    /// A build and a test run are minutes each with nothing to show for them,
    /// and silence on a terminal reads as a hang. Every step that can take
    /// minutes says so before it starts.
    public enum Step: Sendable {
        case building
        /// The compiler rejected these; they were taken out and the build is
        /// being tried again.
        case unviable([Mutant])
        /// The build said which modules the tests are aimed at, and mutants
        /// outside them were left out.
        case scoped(modules: [String], kept: Int, dropped: Int)
        /// Adding the in-process driver and rebuilding the tests.
        case preparingBatch
        /// Each mutant gets a process of its own, and why.
        case oneProcessPerMutant(String)
        case checkingBaseline
        case baselinePassed(TimeInterval)
        /// The batch is done; these mutants sit in values Swift computes once,
        /// and each now runs in a process of its own.
        case evaluatedOnce(Int)
        case started(Mutant)
        case finished(MutantResult, done: Int, of: Int)
    }

    let configuration: Configuration
    let progress: @Sendable (Step) -> Void

    public init(
        configuration: Configuration,
        progress: @escaping @Sendable (Step) -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.progress = progress
    }

    public func callAsFunction(_ mutants: [Mutant]) async throws -> Summary {
        let started = Date()
        let harness = configuration.harness

        progress(.building)
        var mutants = mutants
        let (built, unviable) = try build(&mutants)

        // A mutant in code these tests never look at survives whatever it
        // does, and each one costs a full run to prove it.
        let scope = harness.testedScope(built)
        if let scope {
            let kept = mutants.filter { scope.contains($0.filePath) }
            progress(.scoped(modules: scope.modules, kept: kept.count, dropped: mutants.count - kept.count))
            mutants = kept
        }

        let rejected = unviable.map { MutantResult(mutant: $0, verdict: .error, duration: 0) }

        guard !mutants.isEmpty else {
            return Summary(results: rejected, duration: Date().timeIntervalSince(started))
        }

        if configuration.batching, let batching = harness as? any BatchingHarness {
            if let scope, scope.batchIneligibility == nil {
                progress(.preparingBatch)
                if let plan = try batching.prepareBatch(built, scope: scope, lane: configuration.lanes[0]) {
                    let summary = try await runBatched(plan, mutants, using: batching, started: started)
                    return Summary(results: rejected + summary.results, duration: summary.duration)
                }
            } else {
                progress(.oneProcessPerMutant(
                    scope?.batchIneligibility ?? "could not tell which tests the build runs"
                ))
            }
        }

        // Every mutant is compiled in but switched off here, so this is the
        // project's own suite. Measuring against a red baseline would report
        // mutants as killed by failures that were already there.
        progress(.checkingBaseline)
        let baselineStarted = Date()

        var timeouts = Batch.Timeouts()
        let baseline = try harness.test(
            built,
            lane: configuration.lanes[0],
            switchOn: nil,
            timeout: timeouts.baseline
        )
        let baselineVerdict = TestSuiteOutcome(baseline).verdict
        guard baselineVerdict == .survived else {
            throw Failure.baselineNotGreen(baselineVerdict)
        }

        let baselineDuration = Date().timeIntervalSince(baselineStarted)
        progress(.baselinePassed(baselineDuration))

        // Measured on a whole launch, like every run after it, so ten times
        // this leaves a slow mutant room and still stops an infinite loop.
        timeouts.learn(baseline: baselineDuration)

        let results = try await runEach(
            mutants, built: built, timeout: timeouts.mutant, tally: Tally(total: mutants.count)
        )

        return Summary(results: rejected + results, duration: Date().timeIntervalSince(started))
    }

    /// Builds, taking out whatever the compiler rejects until the rest builds.
    ///
    /// Bounded, because each round is a build: a repair that keeps finding
    /// something new is not converging, and the log says why better than
    /// another attempt would.
    private func build(_ mutants: inout [Mutant]) throws -> (BuiltTests, [Mutant]) {
        var unviable: [Mutant] = []

        for _ in 0..<5 {
            do {
                return (try configuration.harness.build(lane: configuration.lanes[0]), unviable)
            } catch let failure as BuildFailure {
                guard let repair = configuration.repair else { throw failure }

                let pulled = try repair(failure.log, mutants)
                guard !pulled.isEmpty else { throw failure }

                let ids = Set(pulled.map(\.switchName))
                mutants.removeAll { ids.contains($0.switchName) }
                unviable += pulled
                progress(.unviable(pulled))
            }
        }

        return (try configuration.harness.build(lane: configuration.lanes[0]), unviable)
    }

    /// Every lane runs its share of the mutants in one process. The first
    /// lane opens with the baseline, and a red one fails the whole run.
    private func runBatched(
        _ plan: Batch.Plan,
        _ mutants: [Mutant],
        using harness: any BatchingHarness,
        started: Date
    ) async throws -> Summary {
        let lanes = configuration.lanes
        let byID = Dictionary(uniqueKeysWithValues: mutants.map { ($0.switchName, $0) })
        let tally = Tally(total: mutants.count)
        let progress = self.progress

        // A value Swift computes once keeps whichever mutant was on when it
        // was first read, so those get a fresh process each, after the batch.
        let alone = mutants.filter(\.evaluatedOnce)
        let batched = mutants.filter { !$0.evaluatedOnce }

        // Round robin, so each lane gets a mix rather than one file's worth.
        var shares = Array(repeating: [String](), count: lanes.count)
        for (index, mutant) in batched.enumerated() {
            shares[index % lanes.count].append(mutant.switchName)
        }

        progress(.checkingBaseline)

        let outcomes = try await withThrowingTaskGroup(
            of: (verdicts: [String: Verdict], durations: [String: TimeInterval]).self
        ) { group in
            for (index, lane) in lanes.enumerated() {
                let ids = (index == 0 ? [Batch.baseline] : []) + shares[index]
                guard !ids.isEmpty else { continue }

                group.addTask {
                    var durations: [String: TimeInterval] = [:]
                    let verdicts = try harness.runBatch(
                        plan, lane: lane, ids: ids, timeouts: Batch.Timeouts()
                    ) { event in
                        switch event {
                        case .started(Batch.baseline):
                            break
                        case let .finished(Batch.baseline, verdict, duration):
                            if verdict == .survived { progress(.baselinePassed(duration)) }
                        case let .started(id):
                            if let mutant = byID[id] { progress(.started(mutant)) }
                        case let .finished(id, verdict, duration):
                            guard let mutant = byID[id] else { return }
                            durations[id] = duration
                            let result = MutantResult(mutant: mutant, verdict: verdict, duration: duration)
                            progress(.finished(result, done: tally.next(), of: tally.total))
                        }
                    }
                    return (verdicts, durations)
                }
            }

            var verdicts: [String: Verdict] = [:]
            var durations: [String: TimeInterval] = [:]
            for try await outcome in group {
                verdicts.merge(outcome.verdicts) { _, new in new }
                durations.merge(outcome.durations) { _, new in new }
            }
            return (verdicts: verdicts, durations: durations)
        }

        let baseline = outcomes.verdicts[Batch.baseline] ?? .error
        guard baseline == .survived else {
            throw Failure.baselineNotGreen(baseline)
        }

        let results = batched.map { mutant in
            MutantResult(
                mutant: mutant,
                verdict: outcomes.verdicts[mutant.switchName] ?? .error,
                duration: outcomes.durations[mutant.switchName] ?? 0
            )
        }

        if !alone.isEmpty { progress(.evaluatedOnce(alone.count)) }
        // The batch's baseline ran inside a process that was already up, so it
        // says nothing about how long a launch takes; the default allows one.
        let separate = try await runEach(
            alone, built: plan.built, timeout: Batch.Timeouts().mutant, tally: tally
        )

        return Summary(results: results + separate, duration: Date().timeIntervalSince(started))
    }

    /// One fresh process per mutant, one in flight per lane.
    private func runEach(
        _ mutants: [Mutant],
        built: BuiltTests,
        timeout: TimeInterval,
        tally: Tally
    ) async throws -> [MutantResult] {
        let harness = configuration.harness

        // Each task hands its lane back, because that is the one that just came
        // free. Picking by a counter instead would stack two mutants on one
        // simulator while another sat idle.
        return try await withThrowingTaskGroup(
            of: (result: MutantResult, lane: String).self
        ) { group in
            var pending = mutants[...]
            var collected: [MutantResult] = []

            // One in flight per lane. Each worker owns its lane, and they only
            // read what the build produced, so nothing serialises them.
            for lane in configuration.lanes {
                guard let mutant = pending.popFirst() else { break }
                progress(.started(mutant))
                group.addTask {
                    (try run(mutant, in: lane, built: built, timeout: timeout, using: harness), lane)
                }
            }

            while let finished = try await group.next() {
                collected.append(finished.result)
                progress(.finished(finished.result, done: tally.next(), of: tally.total))

                if let mutant = pending.popFirst() {
                    let lane = finished.lane
                    progress(.started(mutant))
                    group.addTask {
                        (try run(mutant, in: lane, built: built, timeout: timeout, using: harness), lane)
                    }
                }
            }

            return collected
        }
    }

    private func run(
        _ mutant: Mutant,
        in lane: String,
        built: BuiltTests,
        timeout: TimeInterval,
        using harness: any TestHarness
    ) throws -> MutantResult {
        let started = Date()
        let log = try harness.test(built, lane: lane, switchOn: mutant.switchName, timeout: timeout)

        return MutantResult(
            mutant: mutant,
            verdict: TestSuiteOutcome(log).verdict,
            duration: Date().timeIntervalSince(started)
        )
    }
}

/// Counts finished mutants across lanes.
private final class Tally: @unchecked Sendable {
    let total: Int
    private var done = 0
    private let lock = NSLock()

    init(total: Int) { self.total = total }

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        done += 1
        return done
    }
}
