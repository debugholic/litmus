import Foundation

/// What the flaky driver wrote for one test target, and what it says about
/// each test.
public struct FlakyRun: Sendable {
    public enum Phase: String, Sendable, CaseIterable {
        /// Each test alone, last first, before anything else ran.
        case reverse
        /// The whole suite.
        case suite
        /// Each test alone, after the suite runs.
        case again
    }

    public struct Outcome: Sendable, Equatable {
        public let phase: Phase
        public let index: Int
        public let test: String
        public let passed: Bool
    }

    /// Where the process stopped before the driver was done.
    public struct Stop: Sendable, Equatable {
        public let phase: Phase
        public let index: Int
        /// Litmus stopped it for taking too long, rather than it crashing.
        public let hung: Bool
    }

    public let target: String
    /// In the order Swift Testing listed them.
    public private(set) var tests: [String] = []
    public private(set) var names: [String: String] = [:]
    public private(set) var outcomes: [Outcome] = []
    /// How long each pass took, by phase and index.
    public private(set) var durations: [String: TimeInterval] = [:]
    public private(set) var finished = false
    public var stop: Stop?

    /// The pass that began and has not ended.
    public private(set) var running: (phase: Phase, index: Int, since: Date)?

    public init(target: String) {
        self.target = target
    }

    /// Takes one line the driver wrote.
    public mutating func read(_ line: String, at time: Date = Date()) {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        switch fields.first {
        case "TEST" where fields.count == 3:
            if names[fields[1]] == nil { tests.append(fields[1]) }
            names[fields[1]] = fields[2]
        case "BEGIN" where fields.count == 3:
            if let phase = Phase(rawValue: fields[1]), let index = Int(fields[2]) {
                running = (phase, index, time)
            }
        case "RESULT" where fields.count == 5:
            if let phase = Phase(rawValue: fields[1]), let index = Int(fields[2]) {
                outcomes.append(Outcome(phase: phase, index: index, test: fields[4], passed: fields[3] == "pass"))
            }
        case "END" where fields.count == 4:
            durations["\(fields[1]) \(fields[2])"] = TimeInterval(fields[3])
            running = nil
        case "DONE":
            finished = true
            running = nil
        default:
            break
        }
    }

    /// The longest pass so far, to judge a stuck one by.
    public var longestPass: TimeInterval { durations.values.max() ?? 0 }

    /// How many times the whole suite ran to the end.
    public var suiteRuns: Int { passes(.suite) }

    /// Passes of a phase that ended.
    public func passes(_ phase: Phase) -> Int {
        durations.keys.count { $0.hasPrefix("\(phase.rawValue) ") }
    }

    /// Where the driver is, for a progress line: `alone 12/75`, `suite 3/10`.
    public func progress(of runs: Int) -> String {
        if passes(.reverse) < tests.count, passes(.suite) == 0 { return "alone \(passes(.reverse))/\(tests.count)" }
        if passes(.suite) < runs { return "suite \(passes(.suite))/\(runs)" }
        return "alone again \(passes(.again))/\(tests.count)"
    }

    /// The test a pass of one test was running, when it stopped there.
    public var stoppedIn: String? {
        guard let stop, stop.phase != .suite else { return nil }
        let order = stop.phase == .reverse ? Array(tests.reversed()) : tests
        return order.indices.contains(stop.index) ? order[stop.index] : nil
    }

    // MARK: - what it says

    public struct Verdict: Sendable, Equatable {
        public let test: String
        public let name: String
        /// Suite runs it failed, of the ones it ran in.
        public let failed: Int
        public let ran: Int
        public let reasons: [String]

        public var isStable: Bool { reasons.isEmpty }

        /// `Module.Suite/function()/File.swift:12:5` gives `File.swift`.
        public var file: String? { TestRef(id: test, name: name).file }
    }

    public var verdicts: [Verdict] {
        tests.map { test in
            let mine = outcomes.filter { $0.test == test }
            let suite = mine.filter { $0.phase == .suite }
            let failed = suite.count { !$0.passed }
            let steady = failed == 0 && !suite.isEmpty

            var reasons: [String] = []
            if failed > 0, failed < suite.count {
                reasons.append("fails \(failed) of \(suite.count) suite runs")
            } else if failed > 0, mine.contains(where: { $0.phase == .reverse && $0.passed }) {
                // It passed once, early, and never again: a test that passes
                // the first time only, or one another test spoils.
                reasons.append("passes on its first run, then fails every suite run — a test run before it leaves state behind")
            } else if failed > 0 {
                reasons.append("fails every time")
            }
            // Read only against a suite that passed every time: after a
            // failing run, failing alone says nothing new.
            if steady, mine.contains(where: { $0.phase == .reverse && !$0.passed }) {
                reasons.append("fails unless a test listed before it runs first")
            }
            if steady, mine.contains(where: { $0.phase == .again && !$0.passed }) {
                reasons.append("fails when run again on its own, after the suite")
            }
            if stoppedIn == test, let stop {
                reasons.append(stop.hung ? "hung when run on its own" : "took the process down when run on its own")
            }

            return Verdict(test: test, name: names[test] ?? test, failed: failed, ran: suite.count, reasons: reasons)
        }
    }
}
