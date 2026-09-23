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
        /// returns them — none when it fixed something else, such as a test
        /// target that never built — or nil when it cannot tell what broke.
        /// Without it, a build that fails ends the run.
        public let repair: (@Sendable (_ log: String, _ mutants: [Mutant]) throws -> [Mutant]?)?

        public init(
            harness: any TestHarness,
            lanes: [String],
            batching: Bool = true,
            repair: (@Sendable (_ log: String, _ mutants: [Mutant]) throws -> [Mutant]?)? = nil
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
        public var timedOut: Int { results.count { $0.verdict == .timedOut } }
        public var unviable: Int { results.count { $0.verdict == .unviable } }
        public var errored: Int { results.count { $0.verdict == .error } }

        /// Caught over everything that actually produced a verdict.
        public var score: Double? { Self.score(results) }

        /// A score for each file, weakest first.
        public var files: [FileScore] {
            let paths = results.map(\.mutant.filePath)
            let root = Self.commonDirectory(of: paths)

            return Dictionary(grouping: results, by: \.mutant.filePath)
                .map { path, results in
                    FileScore(
                        path: root.isEmpty ? path : String(path.dropFirst(root.count)),
                        results: results
                    )
                }
                .sorted { ($0.score ?? 101, $0.path) < ($1.score ?? 101, $1.path) }
        }

        /// Killed and timed out, over those plus survived.
        ///
        /// Mutants that did not build or could not run are left out rather
        /// than counted as killed; folding them in would report a suite as
        /// stronger than it is.
        static func score(_ results: [MutantResult]) -> Double? {
            let caught = results.count { $0.verdict == .killed || $0.verdict == .timedOut }
            let scored = caught + results.count { $0.verdict == .survived }
            guard scored > 0 else { return nil }
            return Double(caught) / Double(scored) * 100
        }

        /// The directory every path sits under, with its trailing slash.
        static func commonDirectory(of paths: [String]) -> String {
            guard let first = paths.first else { return "" }
            var parts = first.split(separator: "/", omittingEmptySubsequences: false).dropLast()

            for path in paths.dropFirst() {
                let other = path.split(separator: "/", omittingEmptySubsequences: false).dropLast()
                let shared = zip(parts, other).prefix { $0 == $1 }.count
                parts = parts.prefix(shared)
            }

            return parts.isEmpty ? "" : parts.joined(separator: "/") + "/"
        }
    }

    public struct FileScore: Sendable {
        /// Relative to the directory all the mutated files share.
        public let path: String
        public let results: [MutantResult]

        public var score: Double? { Summary.score(results) }
        public func count(_ verdict: Verdict) -> Int { results.count { $0.verdict == verdict } }
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
        /// Adding the in-process driver to these test targets and rebuilding.
        case preparingBatch(targets: Int)
        /// Each mutant gets a process of its own running the whole suite,
        /// and why.
        case oneProcessPerMutant(String)
        /// Running a test target against the mutants in the code it tests.
        /// `isolated` says why each mutant gets a process of its own, or is
        /// nil when they share one.
        case target(String, mutants: Int, isolated: String?)
        /// A test target was passed over, and why; its mutants are left to the
        /// other targets that test the same code.
        case targetSkipped(String, reason: String)
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

        let rejected = unviable.map { MutantResult(mutant: $0, verdict: .unviable, duration: 0) }

        guard !mutants.isEmpty else {
            return Summary(results: rejected, duration: Date().timeIntervalSince(started))
        }

        let results: [MutantResult]
        if let scope, !scope.testTargets.isEmpty {
            results = try await runByTarget(mutants, scope: scope, built: built)
        } else {
            if harness is any BatchingHarness {
                progress(.oneProcessPerMutant("could not tell which tests the build runs"))
            }
            results = try await runWholeSuite(mutants, built: built)
        }

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

                guard let pulled = try repair(failure.log, mutants) else { throw failure }
                guard !pulled.isEmpty else { continue }

                let ids = Set(pulled.map(\.switchName))
                mutants.removeAll { ids.contains($0.switchName) }
                unviable += pulled
                progress(.unviable(pulled))
            }
        }

        return (try configuration.harness.build(lane: configuration.lanes[0]), unviable)
    }

    // MARK: - the whole suite

    /// Every mutant against every test, a fresh process each. For when the
    /// build does not say which tests are aimed where.
    private func runWholeSuite(_ mutants: [Mutant], built: BuiltTests) async throws -> [MutantResult] {
        let timeouts = try checkBaseline(built: built, onlyTesting: nil)
        return try await runEach(
            mutants, built: built, onlyTesting: nil,
            timeout: timeouts.mutant, tally: Tally(total: mutants.count)
        )
    }

    /// Runs the suite with nothing switched on, and learns from it how long a
    /// mutant may take.
    ///
    /// Every mutant is compiled in but switched off here, so this is the
    /// project's own suite. Measuring against a red baseline would report
    /// mutants as killed by failures that were already there.
    private func checkBaseline(built: BuiltTests, onlyTesting target: String?) throws -> Batch.Timeouts {
        progress(.checkingBaseline)
        let started = Date()
        var timeouts = Batch.Timeouts()

        let baseline = try configuration.harness.test(
            built,
            lane: configuration.lanes[0],
            switchOn: nil,
            timeout: timeouts.baseline,
            onlyTesting: target
        )
        let verdict = TestSuiteOutcome(baseline).verdict
        guard verdict == .survived else {
            throw Failure.baselineNotGreen(verdict)
        }

        let duration = Date().timeIntervalSince(started)
        progress(.baselinePassed(duration))

        // Measured on a whole launch, like every run after it, so ten times
        // this leaves a slow mutant room and still stops an infinite loop.
        timeouts.learn(baseline: duration)
        return timeouts
    }

    // MARK: - target by target

    /// Each test target runs against the mutants in the code it is aimed at.
    ///
    /// A mutant in code several targets test goes to the next one only if
    /// the last did not catch it, and keeps the best verdict it earned. A
    /// target whose own suite fails is passed over rather than ending the
    /// run, unless it is the only one.
    private func runByTarget(
        _ mutants: [Mutant],
        scope: TestedScope,
        built: BuiltTests
    ) async throws -> [MutantResult] {
        let batching = configuration.batching ? configuration.harness as? any BatchingHarness : nil
        let targets = scope.testTargets.filter { target in
            mutants.contains { target.aims(at: $0.filePath) }
        }

        let batchable = batching == nil
            ? []
            : targets.filter { TestedScope.batchIneligibility(of: $0) == nil }

        var plan: Batch.Plan?
        if let batching, !batchable.isEmpty {
            progress(.preparingBatch(targets: batchable.count))
            plan = try batching.prepareBatch(built, targets: batchable, lane: configuration.lanes[0])
        }
        let runnable = plan?.built ?? built

        var best: [String: MutantResult] = [:]
        func caught(_ mutant: Mutant) -> Bool {
            guard let verdict = best[mutant.switchName]?.verdict else { return false }
            return verdict == .killed || verdict == .timedOut
        }

        for target in targets {
            let share = mutants.filter { target.aims(at: $0.filePath) && !caught($0) }
            guard !share.isEmpty else { continue }

            let inBatch = plan != nil && batchable.contains(target)
            let reason = inBatch
                ? nil
                : (batching == nil ? "asked for" : TestedScope.batchIneligibility(of: target))
            progress(.target(target.name, mutants: share.count, isolated: reason))

            let outcome: [MutantResult]
            do {
                if let plan, let batching, inBatch {
                    outcome = try await runBatched(plan, target: target.name, share, using: batching)
                } else {
                    outcome = try await runIsolated(share, target: target.name, built: runnable)
                }
            } catch let failure as Failure where targets.count > 1 {
                progress(.targetSkipped(target.name, reason: failure.description))
                continue
            }

            for result in outcome {
                if Self.improves(result, on: best[result.mutant.switchName]) {
                    best[result.mutant.switchName] = result
                }
            }
        }

        // A mutant no target could run — every one that tests it was passed
        // over — has no verdict, and is not scored.
        return mutants.map { best[$0.switchName] ?? MutantResult(mutant: $0, verdict: .error, duration: 0) }
    }

    /// Caught beats survived beats could-not-run.
    static func improves(_ new: MutantResult, on old: MutantResult?) -> Bool {
        func rank(_ verdict: Verdict) -> Int {
            switch verdict {
            case .killed, .timedOut: return 2
            case .survived: return 1
            case .unviable, .error: return 0
            }
        }
        guard let old else { return true }
        return rank(new.verdict) > rank(old.verdict)
    }

    /// One target, a fresh process per mutant.
    private func runIsolated(
        _ mutants: [Mutant],
        target: String,
        built: BuiltTests
    ) async throws -> [MutantResult] {
        let timeouts = try checkBaseline(built: built, onlyTesting: target)
        return try await runEach(
            mutants, built: built, onlyTesting: target,
            timeout: timeouts.mutant, tally: Tally(total: mutants.count)
        )
    }

    /// One target, every lane running its share of the mutants in one
    /// process. The first lane opens with the baseline, and a red one fails
    /// the target.
    private func runBatched(
        _ plan: Batch.Plan,
        target: String,
        _ mutants: [Mutant],
        using harness: any BatchingHarness
    ) async throws -> [MutantResult] {
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
                        plan, target: target, lane: lane, ids: ids, timeouts: Batch.Timeouts()
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
            alone, built: plan.built, onlyTesting: target,
            timeout: Batch.Timeouts().mutant, tally: tally
        )

        return results + separate
    }

    /// One fresh process per mutant, one in flight per lane.
    private func runEach(
        _ mutants: [Mutant],
        built: BuiltTests,
        onlyTesting target: String?,
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

            func start(_ mutant: Mutant, on lane: String) {
                progress(.started(mutant))
                group.addTask {
                    let started = Date()
                    let output = try harness.test(
                        built, lane: lane, switchOn: mutant.switchName,
                        timeout: timeout, onlyTesting: target
                    )
                    let result = MutantResult(
                        mutant: mutant,
                        verdict: TestSuiteOutcome(output).verdict,
                        duration: Date().timeIntervalSince(started)
                    )
                    return (result, lane)
                }
            }

            // One in flight per lane. Each worker owns its lane, and they only
            // read what the build produced, so nothing serialises them.
            for lane in configuration.lanes {
                guard let mutant = pending.popFirst() else { break }
                start(mutant, on: lane)
            }

            while let finished = try await group.next() {
                collected.append(finished.result)
                progress(.finished(finished.result, done: tally.next(), of: tally.total))

                if let mutant = pending.popFirst() {
                    start(mutant, on: finished.lane)
                }
            }

            return collected
        }
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
