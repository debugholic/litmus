import Foundation

/// Drives one mutation testing run: build once, then flip mutants on one at a time.
public struct MutationRun: Sendable {
    public struct Configuration: Sendable {
        /// How the project's tests get built and run.
        public let harness: any TestHarness
        /// One lane per worker: a simulator for xcodebuild, a plain slot for a
        /// Swift package. One entry means sequential.
        public let lanes: [String]

        public init(harness: any TestHarness, lanes: [String]) {
            self.harness = harness
            self.lanes = lanes
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

    let configuration: Configuration
    let progress: @Sendable (MutantResult) -> Void

    public init(
        configuration: Configuration,
        progress: @escaping @Sendable (MutantResult) -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.progress = progress
    }

    public func callAsFunction(_ mutants: [Mutant]) async throws -> Summary {
        let started = Date()
        let harness = configuration.harness

        let built = try harness.build(lane: configuration.lanes[0])

        // Every mutant is compiled in but switched off here, so this is the
        // project's own suite. Measuring against a red baseline would report
        // mutants as killed by failures that were already there.
        let baseline = try harness.test(
            built,
            lane: configuration.lanes[0],
            switchOn: nil
        )
        let baselineVerdict = TestSuiteOutcome(baseline).verdict
        guard baselineVerdict == .survived else {
            throw Failure.baselineNotGreen(baselineVerdict)
        }

        // Each task hands its lane back, because that is the one that just came
        // free. Picking by a counter instead would stack two mutants on one
        // simulator while another sat idle.
        let results = try await withThrowingTaskGroup(
            of: (result: MutantResult, lane: String).self
        ) { group in
            var pending = mutants[...]
            var collected: [MutantResult] = []

            // One in flight per lane. Each worker owns its lane, and they only
            // read what the build produced, so nothing serialises them.
            for lane in configuration.lanes {
                guard let mutant = pending.popFirst() else { break }
                group.addTask {
                    (try run(mutant, in: lane, built: built, using: harness), lane)
                }
            }

            while let finished = try await group.next() {
                collected.append(finished.result)
                progress(finished.result)

                if let mutant = pending.popFirst() {
                    let lane = finished.lane
                    group.addTask {
                        (try run(mutant, in: lane, built: built, using: harness), lane)
                    }
                }
            }

            return collected
        }

        return Summary(results: results, duration: Date().timeIntervalSince(started))
    }

    private func run(
        _ mutant: Mutant,
        in lane: String,
        built: BuiltTests,
        using harness: any TestHarness
    ) throws -> MutantResult {
        let started = Date()
        let log = try harness.test(built, lane: lane, switchOn: mutant.switchName)

        return MutantResult(
            mutant: mutant,
            verdict: TestSuiteOutcome(log).verdict,
            duration: Date().timeIntervalSince(started)
        )
    }
}
