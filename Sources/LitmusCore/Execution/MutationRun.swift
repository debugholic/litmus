import Foundation

/// Drives one mutation testing run: build once, then flip mutants on one at a time.
public struct MutationRun: Sendable {
    public struct Configuration: Sendable {
        public let project: URL
        public let scheme: String
        /// Simulators to spread the work over. One entry means sequential.
        public let destinations: [String]
        public let derivedDataPath: URL

        public init(
            project: URL,
            scheme: String,
            destinations: [String],
            derivedDataPath: URL
        ) {
            self.project = project
            self.scheme = scheme
            self.destinations = destinations
            self.derivedDataPath = derivedDataPath
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
        let xcodebuild = Xcodebuild(workingDirectory: configuration.project)

        let xctestrun = try xcodebuild.buildForTesting(
            scheme: configuration.scheme,
            destination: configuration.destinations[0],
            derivedDataPath: configuration.derivedDataPath
        )

        // Every mutant is compiled in but switched off here, so this is the
        // project's own suite. Measuring against a red baseline would report
        // mutants as killed by failures that were already there.
        let baseline = try xcodebuild.testWithoutBuilding(
            xctestrun: xctestrun,
            destination: configuration.destinations[0]
        )
        let baselineVerdict = TestSuiteOutcome(log: baseline).verdict
        guard baselineVerdict == .survived else {
            throw Failure.baselineNotGreen(baselineVerdict)
        }

        // Each task hands its simulator back, because that is the one that just
        // came free. Picking by a counter instead would stack two mutants on
        // one simulator while another sat idle.
        let results = try await withThrowingTaskGroup(
            of: (result: MutantResult, destination: String).self
        ) { group in
            var pending = mutants[...]
            var collected: [MutantResult] = []

            // One in flight per destination. Each worker owns a simulator, and
            // they share the .xctestrun read-only, so nothing serialises them.
            for destination in configuration.destinations {
                guard let mutant = pending.popFirst() else { break }
                group.addTask {
                    (try run(mutant, on: destination, xctestrun: xctestrun, using: xcodebuild), destination)
                }
            }

            while let finished = try await group.next() {
                collected.append(finished.result)
                progress(finished.result)

                if let mutant = pending.popFirst() {
                    let destination = finished.destination
                    group.addTask {
                        (try run(mutant, on: destination, xctestrun: xctestrun, using: xcodebuild), destination)
                    }
                }
            }

            return collected
        }

        return Summary(results: results, duration: Date().timeIntervalSince(started))
    }

    private func run(
        _ mutant: Mutant,
        on destination: String,
        xctestrun: URL,
        using xcodebuild: Xcodebuild
    ) throws -> MutantResult {
        let started = Date()
        let log = try xcodebuild.testWithoutBuilding(
            xctestrun: xctestrun,
            destination: destination,
            switchOn: mutant.switchName
        )

        return MutantResult(
            mutant: mutant,
            verdict: TestSuiteOutcome(log: log).verdict,
            duration: Date().timeIntervalSince(started)
        )
    }
}
