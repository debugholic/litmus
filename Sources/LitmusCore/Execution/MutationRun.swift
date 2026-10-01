import Foundation
import os

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
        /// target that never built — or says it moved operators back to a
        /// copy, or nil when it cannot tell what broke. Without it, a build
        /// that fails ends the run.
        public let repair: (@Sendable (_ log: String, _ mutants: [Mutant]) throws -> BuildFix?)?

        public init(
            harness: any TestHarness,
            lanes: [String],
            batching: Bool = true,
            repair: (@Sendable (_ log: String, _ mutants: [Mutant]) throws -> BuildFix?)? = nil
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

    /// What a repair did to a build that failed.
    public enum BuildFix: Sendable {
        /// Took these out — none when it fixed something else, such as a
        /// test target that never built.
        case removed([Mutant])
        /// Moved operators from a call back to a copy of their expression;
        /// nothing was taken out.
        case moved
    }

    public struct Summary: Sendable {
        public let results: [MutantResult]
        public let duration: TimeInterval
        /// The module each mutated file was compiled into, when the build
        /// said; see `areas`.
        public var modules: [String: String] = [:]
        /// Where the time went; the mutants had what is left of `duration`.
        public var phases = Phases()

        /// Tests that passed in the suite and failed when run again on their
        /// own, while probing: they depend on state the run left behind, or
        /// they are flaky.
        public var failedAlone: [TestRef] = []

        /// Kills that rest on those tests alone. A mutant runs the same way,
        /// in the same process with only the tests that reach it, so a test
        /// that fails there without a mutant fails with one too, and the kill
        /// may not be the mutant's doing.
        public var unsureKills: [MutantResult] {
            let alone = Set(failedAlone.map(\.id))
            guard !alone.isEmpty else { return [] }
            return results.filter { result in
                result.verdict == .killed && !result.killedBy.isEmpty
                    && result.killedBy.allSatisfy { alone.contains($0.id) }
            }
        }

        /// Running the mutants: the run's time less building and the baseline.
        public var mutantTime: TimeInterval { max(0, duration - phases.build - phases.baseline) }

        /// The whole run: `duration` is only the part after the mutants were
        /// written.
        public var total: TimeInterval { phases.setup + phases.coverage + duration }

        public var killed: Int { results.count { $0.verdict == .killed } }
        public var survived: Int { results.count { $0.verdict == .survived } }
        public var timedOut: Int { results.count { $0.verdict == .timedOut } }
        public var unviable: Int { results.count { $0.verdict == .unviable } }
        public var noCoverage: Int { results.count { $0.verdict == .noCoverage } }
        public var errored: Int { results.count { $0.verdict == .error } }

        /// Caught over everything that actually produced a verdict.
        public var score: Double? { Self.score(results) }

        /// The same as `score`, by the name other reports give it: how much
        /// of what the tests reach they catch.
        public var testStrength: Double? { score }

        /// Caught over every mutant that ran, reached or not: how much of the
        /// code the tests guard. Mutants that did not build or could not run
        /// are left out, as they are from `score`.
        public var mutationScore: Double? {
            let caught = results.count { $0.verdict == .killed || $0.verdict == .timedOut }
            let total = caught + survived + noCoverage
            guard total > 0 else { return nil }
            return Double(caught) / Double(total) * 100
        }

        /// What falls short of the thresholds given, one sentence each; empty
        /// when nothing does. A score with nothing to measure — no mutant the
        /// tests reach — falls short of nothing: there is nothing to judge.
        public func shortfalls(testStrength least: Double?, mutationScore wholeLeast: Double?) -> [String] {
            var found: [String] = []
            if let least, let score = testStrength, score < least {
                found.append("Litmus score \(Int(score.rounded()))% is under \(Int(least.rounded()))%")
            }
            if let wholeLeast, let score = mutationScore, score < wholeLeast {
                found.append("mutation score \(Int(score.rounded()))% is under \(Int(wholeLeast.rounded()))%")
            }
            return found
        }

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

        /// A score for each module, or, when everything is in one, for each
        /// top-level folder under the files' common root: one row for one
        /// module says nothing a second time. Weakest first, those with no
        /// score last.
        /// Whether `areas` are modules rather than folders.
        public var areasAreModules: Bool {
            Set(results.compactMap { modules[$0.mutant.filePath] }).count > 1
        }

        public var areas: [AreaScore] {
            let named = Set(results.compactMap { modules[$0.mutant.filePath] })
            let root = Self.commonDirectory(of: results.map(\.mutant.filePath))

            func area(of result: MutantResult) -> String {
                if named.count > 1, let module = modules[result.mutant.filePath] { return module }
                let relative = root.isEmpty ? result.mutant.filePath : String(result.mutant.filePath.dropFirst(root.count))
                let parts = relative.split(separator: "/")
                return parts.count > 1 ? String(parts[0]) : "(root)"
            }

            return Dictionary(grouping: results, by: area)
                .map { AreaScore(name: $0.key, results: $0.value) }
                .sorted { ($0.score ?? 101, $0.name) < ($1.score ?? 101, $1.name) }
        }

        /// Every test that reached a mutant, costliest first.
        public var tests: [TestScore] {
            var byID: [String: (test: TestRef, reached: Int, killed: Int)] = [:]
            for result in results {
                for test in result.coveredBy {
                    byID[test.id, default: (test, 0, 0)].reached += 1
                }
                for test in result.killedBy {
                    byID[test.id, default: (test, 0, 0)].killed += 1
                }
            }
            return byID.values
                .map { TestScore(test: $0.test, reached: $0.reached, killed: $0.killed) }
                .sorted { ($0.cost ?? -1, $0.test.id) > ($1.cost ?? -1, $1.test.id) }
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

    /// A test, with what it did across the run.
    public struct TestScore: Sendable {
        public let test: TestRef
        /// Mutants it ran against: each one a run of this test.
        public let reached: Int
        public let killed: Int

        /// What the test costs the run: its time once for every mutant it
        /// reaches.
        public var cost: TimeInterval? { test.duration.map { $0 * Double(reached) } }
    }

    /// Where a run's time went.
    public struct Phases: Sendable, Equatable {
        /// Copying the project and writing the mutants into it, before the
        /// run; the coverage run is not in it.
        public var setup: TimeInterval = 0
        /// The coverage run, when there was one. On a project with XCTest it
        /// can be the longest part of all.
        public var coverage: TimeInterval = 0
        /// Building, rebuilding after a rejected mutant, and adding the driver.
        public var build: TimeInterval = 0
        /// Launching the tests, the baseline and the probe.
        public var baseline: TimeInterval = 0

        public init(
            setup: TimeInterval = 0, coverage: TimeInterval = 0,
            build: TimeInterval = 0, baseline: TimeInterval = 0
        ) {
            self.setup = setup
            self.coverage = coverage
            self.build = build
            self.baseline = baseline
        }
    }

    /// Tests that failed when run again on their own, from every lane's
    /// probe.
    private final class Apart: Sendable {
        private let found = OSAllocatedUnfairLock(initialState: [String: TestRef]())

        func add(_ test: TestRef) {
            found.withLock { $0[test.id] = test }
        }

        var tests: [TestRef] {
            found.withLock { $0.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) } }
        }
    }

    private final class Clock: Sendable {
        private let measured = OSAllocatedUnfairLock(initialState: Phases())

        func add(build: TimeInterval = 0, baseline: TimeInterval = 0) {
            measured.withLock {
                $0.build += build
                $0.baseline += baseline
            }
        }

        var phases: Phases {
            measured.withLock { $0 }
        }
    }

    /// A module, or a top-level folder, and its mutants.
    public struct AreaScore: Sendable {
        public let name: String
        public let results: [MutantResult]

        public var score: Double? { Summary.score(results) }
        public func count(_ verdict: Verdict) -> Int { results.count { $0.verdict == verdict } }
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
        /// Running each test alone to see which mutants it reaches.
        case probing
        /// Done: mutants now run only the tests that reach them.
        case probed(TimeInterval)
        /// The batch is done; these mutants sit in values Swift computes once,
        /// and each now runs in a process of its own.
        case evaluatedOnce(Int)
        case started(Mutant)
        case finished(MutantResult, done: Int, of: Int)
    }

    let configuration: Configuration
    let progress: @Sendable (Step) -> Void
    /// Where the run's time went, added to as it goes.
    private let clock = Clock()
    private let apart = Apart()

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
        let buildStarted = Date()
        let (built, unviable) = try await build(&mutants)
        clock.add(build: Date().timeIntervalSince(buildStarted))

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

        var summary = Summary(results: rejected + results, duration: Date().timeIntervalSince(started))
        summary.phases = clock.phases
        summary.failedAlone = apart.tests
        if let scope {
            for path in Set(summary.results.map(\.mutant.filePath)) {
                summary.modules[path] = scope.module(of: path)
            }
        }
        return summary
    }

    /// Builds, taking out whatever the compiler rejects until the rest builds.
    ///
    /// A round that takes a mutant out, or moves one back to a copy, is
    /// progress there is only so much of. The rounds that do neither — a test
    /// target left out — are bounded, because each is a build and a repair
    /// that keeps finding something new is not converging.
    private func build(_ mutants: inout [Mutant]) async throws -> (BuiltTests, [Mutant]) {
        var unviable: [Mutant] = []
        var rounds = 0
        var moves = 0

        while rounds < 5 {
            do {
                return (try await configuration.harness.build(lane: configuration.lanes[0]), unviable)
            } catch let failure as BuildFailure {
                guard let repair = configuration.repair else { throw failure }
                guard let fix = try repair(failure.log, mutants) else { throw failure }

                // A move takes nothing out, so it does not count against the
                // rounds: each sends at least one call back to a copy, and
                // there are only so many to send.
                let pulled: [Mutant]
                switch fix {
                case .moved:
                    moves += 1
                    guard moves <= mutants.count else { throw failure }
                    continue
                case let .removed(removed):
                    // Taking mutants out does not count either: a build that
                    // names one file's rejections at a time takes a round per
                    // file, and there are only so many mutants to take.
                    if removed.isEmpty { rounds += 1 }
                    pulled = removed
                }
                guard !pulled.isEmpty else { continue }

                let ids = Set(pulled.map(\.switchName))
                mutants.removeAll { ids.contains($0.switchName) }
                unviable += pulled
                progress(.unviable(pulled))
            }
        }

        return (try await configuration.harness.build(lane: configuration.lanes[0]), unviable)
    }

    // MARK: - the whole suite

    /// Every mutant against every test, a fresh process each. For when the
    /// build does not say which tests are aimed where.
    private func runWholeSuite(_ mutants: [Mutant], built: BuiltTests) async throws -> [MutantResult] {
        let timeouts = try await checkBaseline(built: built, onlyTesting: nil)
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
    private func checkBaseline(built: BuiltTests, onlyTesting target: String?) async throws -> Batch.Timeouts {
        progress(.checkingBaseline)
        let started = Date()
        var timeouts = Batch.Timeouts()

        let baseline = try await configuration.harness.test(
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
        clock.add(baseline: duration)
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
            let prepared = Date()
            plan = try await batching.prepareBatch(built, targets: batchable, lane: configuration.lanes[0])
            clock.add(build: Date().timeIntervalSince(prepared))
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
            } catch is CancellationError {
                throw CancellationError()
            } catch where targets.count > 1 {
                // One target that cannot run — a red baseline, a runner that
                // would not launch — is no reason to lose the others.
                progress(.targetSkipped(target.name, reason: "\(error)"))
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
            case .noCoverage, .unviable, .error: return 0
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
        let timeouts = try await checkBaseline(built: built, onlyTesting: target)
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
        let batchStarted = Date()
        let clock = self.clock
        let apart = self.apart

        let outcomes = try await withThrowingTaskGroup(
            of: (
                verdicts: [String: Verdict],
                durations: [String: TimeInterval],
                reached: Set<String>?,
                tests: [String: (covered: [TestRef], killed: [TestRef])]
            ).self
        ) { group in
            for (index, lane) in lanes.enumerated() {
                // Every lane checks the suite and probes for itself. With the
                // first alone probing, a mutant no test reaches came out as no
                // coverage on one lane and a survivor on the others, and the
                // score moved with how the mutants were dealt. The lanes run
                // side by side, so it costs no time.
                guard index == 0 || !shares[index].isEmpty else { continue }
                let ids = [Batch.baseline] + shares[index]
                let lead = index == 0

                group.addTask {
                    // Until the first mutant starts on the first lane: the
                    // launch, the baseline and the probe.
                    var readied = false
                    func ready() {
                        guard lead, !readied else { return }
                        readied = true
                        clock.add(baseline: Date().timeIntervalSince(batchStarted))
                    }
                    defer { ready() }
                    var durations: [String: TimeInterval] = [:]
                    var reached: Set<String> = []
                    var probed = false
                    var names: [String: String] = [:]
                    var times: [String: TimeInterval] = [:]
                    var tests: [String: (covered: [TestRef], killed: [TestRef])] = [:]
                    func refs(_ ids: [String]) -> [TestRef] {
                        ids.map { TestRef(id: $0, name: names[$0] ?? $0, duration: times[$0]) }
                    }
                    let verdicts = try await harness.runBatch(
                        plan, target: target, lane: lane, ids: ids, timeouts: Batch.Timeouts()
                    ) { event in
                        switch event {
                        case .started(Batch.baseline):
                            break
                        case .started(Batch.probe):
                            if lead { progress(.probing) }
                        case let .finished(Batch.probe, verdict, duration):
                            probed = verdict == .survived
                            if lead { progress(.probed(duration)) }
                        case let .reached(id):
                            reached.insert(id)
                        case let .test(id, name):
                            names[id] = name
                        case let .timed(id, seconds):
                            times[id] = seconds
                        case let .failedAlone(id):
                            apart.add(TestRef(id: id, name: names[id] ?? id, duration: times[id]))
                        case let .covered(id, ids):
                            tests[id, default: ([], [])].covered = refs(ids)
                        case let .killedBy(id, ids):
                            tests[id, default: ([], [])].killed = refs(ids)
                        case let .finished(Batch.baseline, verdict, duration):
                            if lead, verdict == .survived { progress(.baselinePassed(duration)) }
                        case let .started(id):
                            if let mutant = byID[id] {
                                ready()
                                progress(.started(mutant))
                            }
                        case let .finished(id, verdict, duration):
                            guard let mutant = byID[id] else { return }
                            durations[id] = duration
                            var result = MutantResult(mutant: mutant, verdict: verdict, duration: duration)
                            result.coveredBy = tests[id]?.covered ?? []
                            result.killedBy = tests[id]?.killed ?? []
                            progress(.finished(result, done: tally.next(), of: tally.total))
                        }
                    }
                    // Only a probe that finished has seen every switch the
                    // tests pass through.
                    return (verdicts, durations, probed ? reached : nil, tests)
                }
            }

            var verdicts: [String: Verdict] = [:]
            var durations: [String: TimeInterval] = [:]
            var reached: Set<String>?
            var tests: [String: (covered: [TestRef], killed: [TestRef])] = [:]
            for try await outcome in group {
                // Every lane has its own baseline; one that did not pass is
                // the verdict, whichever lane finished last.
                let base = [verdicts[Batch.baseline], outcome.verdicts[Batch.baseline]]
                    .compactMap { $0 }
                    .first { $0 != .survived } ?? outcome.verdicts[Batch.baseline] ?? verdicts[Batch.baseline]
                verdicts.merge(outcome.verdicts) { _, new in new }
                verdicts[Batch.baseline] = base
                durations.merge(outcome.durations) { _, new in new }
                if let seen = outcome.reached { reached = (reached ?? []).union(seen) }
                tests.merge(outcome.tests) { _, new in new }
            }
            return (verdicts: verdicts, durations: durations, reached: reached, tests: tests)
        }

        let baseline = outcomes.verdicts[Batch.baseline] ?? .error
        guard baseline == .survived else {
            throw Failure.baselineNotGreen(baseline)
        }

        let results = batched.map { mutant in
            var result = MutantResult(
                mutant: mutant,
                verdict: outcomes.verdicts[mutant.switchName] ?? .error,
                duration: outcomes.durations[mutant.switchName] ?? 0
            )
            result.coveredBy = outcomes.tests[mutant.switchName]?.covered ?? []
            result.killedBy = outcomes.tests[mutant.switchName]?.killed ?? []
            return result
        }

        // A process of its own is a launch, half a minute on a simulator. One
        // the tests never read, from launch to the end of the probe, would
        // survive it, and needs none.
        let unreached = outcomes.reached.map { seen in alone.filter { !seen.contains($0.switchName) } } ?? []
        let skipped = unreached.map { mutant in
            let result = MutantResult(mutant: mutant, verdict: .noCoverage, duration: 0)
            progress(.finished(result, done: tally.next(), of: tally.total))
            return result
        }
        let launched = alone.filter { mutant in !unreached.contains { $0 == mutant } }

        if !launched.isEmpty { progress(.evaluatedOnce(launched.count)) }

        // The batch's baseline ran inside a process that was already up, so it
        // says nothing about how long a launch takes; the default allows one.
        let separate = try await runEach(
            launched, built: plan.built, onlyTesting: target,
            timeout: Batch.Timeouts().mutant, tally: tally
        )

        return results + skipped + separate
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
                    let output = try await harness.test(
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
private final class Tally: Sendable {
    let total: Int
    private let done = OSAllocatedUnfairLock(initialState: 0)

    init(total: Int) { self.total = total }

    func next() -> Int {
        done.withLock {
            $0 += 1
            return $0
        }
    }
}
