import Foundation

/// Running many mutants in one test process.
///
/// On a simulator, launching is most of what a mutant costs: installing the
/// app and starting the runner took 85 of every 115 seconds, and the tests the
/// other 30. So the tests are launched once per batch, and a driver inside the
/// test bundle switches from one mutant to the next, rerunning the suite each
/// time. Thirty-four mutants took 99 seconds this way against 65 minutes one
/// launch at a time, and every verdict checked against a fresh process agreed.
public enum Batch {
    /// What a batch run needs: the rebuilt tests, and the target the driver
    /// was added to.
    public struct Plan: Sendable {
        /// Rebuilt, with the driver in every target that has one.
        public let built: BuiltTests
    }

    /// Something the driver reported.
    public enum Event: Sendable, Equatable {
        case started(String)
        case finished(String, Verdict, TimeInterval)
        /// A mutant switch the tests passed through at least once, from the
        /// process's start to the end of the probe.
        case reached(String)
        /// A test the probe listed, by its id and the name it was given.
        case test(id: String, name: String)
        /// The tests a mutant was run against: the ones that reach it.
        case covered(String, tests: [String])
        /// The tests that failed with the mutant on.
        case killedBy(String, tests: [String])
        /// How long a test took on its own, while probing.
        case timed(String, seconds: TimeInterval)
        /// A test that failed when run again on its own, while probing,
        /// though the suite had just passed with it in: it depends on state
        /// the run left behind, or it is flaky.
        case failedAlone(String)
    }

    /// How long to wait before deciding a launch or a mutant is stuck.
    public struct Timeouts: Sendable {
        /// Until the driver reports anything: building nothing, but
        /// installing and launching an app.
        public var launch: TimeInterval = 20 * 60
        /// For the unmutated run, which sets the measure for the rest.
        public var baseline: TimeInterval = 15 * 60
        /// For a mutant, until the baseline says how long a run should take.
        public var mutant: TimeInterval = 5 * 60
        /// The least a mutant is ever allowed, however quick the baseline.
        public var floor: TimeInterval = 60

        public init() {}

        /// Ten times the baseline, and never less than the floor. A mutant
        /// that turns a loop infinite has to be stopped, and one that only
        /// makes a test slower should not be.
        mutating func learn(baseline duration: TimeInterval) {
            mutant = max(floor, duration * 10)
        }

        /// How long each test took alone, from the probe.
        var tests: [String: TimeInterval] = [:]

        /// Ten times what the tests a mutant runs took alone, and never less
        /// than the floor. The baseline is a poor measure here: it carries the
        /// process's first run, and moved between 2s and 25s from one run to
        /// the next, taking a hung mutant's allowance from one minute to four.
        /// Without a time for every one of the tests, the baseline's measure.
        func mutant(running ids: [String]) -> TimeInterval {
            let times = ids.compactMap { tests[$0] }
            guard !ids.isEmpty, times.count == ids.count else { return mutant }
            return max(floor, times.reduce(0, +) * 10)
        }
    }

    /// The name that stands for "no mutant" in a batch.
    public static let baseline = "-"

    static let batchFileVariable = "LITMUS_BATCH_FILE"
    static let resultsFileVariable = "LITMUS_RESULTS_FILE"
    static let driverClass = "__LitmusDriver"
    static let driverTest = "test__litmus"
    static let probeDirectoryVariable = "LITMUS_PROBE_DIR"
    /// What Swift Testing returns when a filter matches no test.
    static let noTestsFound = 69
    /// The step after the baseline that runs each test alone to see which
    /// mutants it reaches.
    public static let probe = "~probe"
    /// The probe file switches go to from the moment the test process starts,
    /// before any test is singled out.
    static let launchProbe = "launch.probe"
    /// The first line of the driver, so the tests' own code can be told apart.
    static let driverMarker = "// ─── Added by litmus to its working copy."

    /// The test that runs the batch, appended to a file of the test target.
    ///
    /// Appended rather than added as a new file, so no project file has to
    /// change and it works the same for a package, a project or Tuist. It only
    /// ever lands in litmus's working copy, which is a clone: writing to it
    /// leaves the original alone.
    static let driver = """


    // ─── Added by litmus to its working copy. Never part of your project. ───
    // Runs every mutant of a batch in this one process, so the app is
    // installed and launched once rather than once per mutant.
    import Foundation
    import Testing
    import XCTest

    final class \(driverClass): XCTestCase {
        func \(driverTest)() async throws {
            let environment = ProcessInfo.processInfo.environment
            guard
                let batchPath = environment["\(batchFileVariable)"],
                let resultsPath = environment["\(resultsFileVariable)"],
                let batch = try? String(contentsOfFile: batchPath, encoding: .utf8)
            else { return }
            let probeDirectory = environment["\(probeDirectoryVariable)"]

            FileManager.default.createFile(atPath: resultsPath, contents: nil)
            guard let results = FileHandle(forWritingAtPath: resultsPath) else { return }
            defer { try? results.close() }

            func record(_ line: String) {
                _ = try? results.seekToEnd()
                try? results.write(contentsOf: Data((line + "\\n").utf8))
                try? results.synchronize()
            }

            func run(_ filter: [String]?, stream: String? = nil) async -> CInt {
                var arguments = __CommandLineArguments_v0()
                arguments.parallel = false
                arguments.quiet = true
                arguments.filter = filter
                if let stream {
                    arguments.eventStreamOutputPath = stream
                    arguments.eventStreamSchemaVersion = "0"
                }
                return await __swiftPMEntryPoint(passing: arguments)
            }

            // Where a mutant's run says which tests failed.
            let stream = NSTemporaryDirectory() + "litmus-run-\\(getpid()).jsonl"

            // Which tests reach each mutant, keyed by mutant id. Nil runs
            // every test for every mutant.
            var reaching: [String: [String]]?

            for id in batch.split(separator: "\\n").map(String.init) where !id.isEmpty {
                if id == "\(baseline)" {
                    unsetenv("\(MutationSwitch.activeVariable)")
                    record("START \\(id)")
                    let started = Date()
                    let code = await run(nil)
                    record("END \\(id) \\(code == 0 ? "survived" : "killed") \\(Date().timeIntervalSince(started))")

                    // Measured against a failing suite, every mutant looks killed.
                    if code != 0 { break }

                    if let probeDirectory {
                        record("START \(probe)")
                        let probed = Date()
                        let found = await Self.probe(in: probeDirectory) { await run($0) }
                        reaching = found.reaching
                        for (test, name) in found.names.sorted(by: { $0.key < $1.key }) {
                            record("TEST\\t\\(Self.field(test))\\t\\(Self.field(name))")
                        }
                        for (test, seconds) in found.durations.sorted(by: { $0.key < $1.key }) {
                            record("TIME\\t\\(Self.field(test))\\t\\(seconds)")
                        }
                        for test in found.failedAlone {
                            record("ALONE\\t\\(Self.field(test))")
                        }
                        for id in Self.reached(in: probeDirectory) {
                            record("REACHED \\(id)")
                        }
                        record("END \(probe) survived \\(Date().timeIntervalSince(probed))")
                    }
                    continue
                }

                // A relaunch after a crash reads what the first launch probed.
                if reaching == nil, let probeDirectory {
                    reaching = Self.readMap(in: probeDirectory)
                }

                var filter: [String]?
                if let reaching {
                    let tests = reaching[id] ?? []
                    guard !tests.isEmpty else {
                        record("START \\(id)")
                        record("END \\(id) nocoverage 0")
                        continue
                    }
                    filter = tests.map { NSRegularExpression.escapedPattern(for: $0) }
                }

                setenv("\(MutationSwitch.activeVariable)", id, 1)
                record("START \\(id)")
                if let tests = reaching?[id] {
                    record((["COVERED", id] + tests.map(Self.field)).joined(separator: "\\t"))
                }
                try? FileManager.default.removeItem(atPath: stream)
                let started = Date()
                let code = await run(filter, stream: stream)
                let verdict = Self.verdict(code)
                if verdict == "killed" {
                    let failed = Self.failed(in: stream)
                    if !failed.isEmpty {
                        record((["KILLEDBY", id] + failed.map(Self.field)).joined(separator: "\\t"))
                    }
                }
                record("END \\(id) \\(verdict) \\(Date().timeIntervalSince(started))")
            }

            unsetenv("\(MutationSwitch.activeVariable)")
        }

        /// Swift Testing's exit codes: 0 when every test passed, 69 when the
        /// filter matched no test at all. That is not the mutant's doing, and
        /// reading it as a failure would score a kill that never happened.
        private static func verdict(_ code: CInt) -> String {
            switch code {
            case 0: return "survived"
            case \(noTestsFound): return "error"
            default: return "killed"
            }
        }

        /// Runs each test on its own, noting which mutant switches it passes
        /// through. A switch no test passes through is code no test reaches.
        private static func probe(
            in directory: String,
            run: ([String]?) async -> CInt
        ) async -> (
            reaching: [String: [String]], names: [String: String], durations: [String: TimeInterval],
            failedAlone: [String]
        ) {
            let listing = directory + "/tests.jsonl"
            var arguments = __CommandLineArguments_v0()
            arguments.listTests = true
            arguments.eventStreamOutputPath = listing
            arguments.eventStreamSchemaVersion = "0"
            let _: CInt = await __swiftPMEntryPoint(passing: arguments)

            var tests: [String] = []
            var names: [String: String] = [:]
            for line in ((try? String(contentsOfFile: listing, encoding: .utf8)) ?? "").split(separator: "\\n") {
                guard
                    let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                    object["kind"] as? String == "test",
                    let payload = object["payload"] as? [String: Any],
                    payload["kind"] as? String == "function",
                    let id = payload["id"] as? String
                else { continue }
                tests.append(id)
                // The name the test was given, `@Test("…")`, else its function.
                names[id] = (payload["displayName"] as? String) ?? (payload["name"] as? String) ?? id
            }

            var reaching: [String: [String]] = [:]
            var durations: [String: TimeInterval] = [:]
            // The suite passed just before, in this same process, so a test
            // that fails here depends on state the run left behind, or is
            // flaky. Either way it fails in a mutant's run too, mutant or
            // not. A test that needs another to run first is not seen: that
            // one has run already, and what it set is still set.
            var failedAlone: [String] = []
            for (index, test) in tests.enumerated() {
                let file = directory + "/\\(index).probe"
                setenv("\(MutationSwitch.probeVariable)", file, 1)
                let started = Date()
                let code = await run([NSRegularExpression.escapedPattern(for: test)])
                durations[test] = Date().timeIntervalSince(started)
                if code != 0, code != \(noTestsFound) { failedAlone.append(test) }
                unsetenv("\(MutationSwitch.probeVariable)")

                for id in ((try? String(contentsOfFile: file, encoding: .utf8)) ?? "").split(separator: "\\n") {
                    reaching[String(id), default: []].append(test)
                }
            }

            let map = reaching.map { ([$0.key] + $0.value).joined(separator: "\\t") }.joined(separator: "\\n")
            try? map.write(toFile: directory + "/map.tsv", atomically: true, encoding: .utf8)
            return (reaching, names, durations, failedAlone)
        }

        /// The tests that recorded an issue in a run's event stream: the ones
        /// the mutant made fail.
        private static func failed(in stream: String) -> [String] {
            var failed: [String] = []
            for line in ((try? String(contentsOfFile: stream, encoding: .utf8)) ?? "").split(separator: "\\n") {
                guard
                    let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                    let payload = object["payload"] as? [String: Any],
                    payload["kind"] as? String == "issueRecorded",
                    let test = payload["testID"] as? String,
                    !failed.contains(test)
                else { continue }
                // An issue the test expects, `withKnownIssue`, fails nothing.
                if let issue = payload["issue"] as? [String: Any], issue["isKnown"] as? Bool == true { continue }
                failed.append(test)
            }
            return failed
        }

        /// A field of a tab-separated line, with anything that would split it
        /// flattened to a space.
        private static func field(_ text: String) -> String {
            text.map { $0 == "\\t" || $0 == "\\n" || $0 == "\\r" ? " " : $0 }.reduce(into: "") { $0.append($1) }
        }

        /// Every switch noted in any probe file, the one kept from launch
        /// included. A value Swift computes once is read before the probe, by
        /// the baseline or by whatever runs first, and only that file sees it.
        private static func reached(in directory: String) -> Set<String> {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            var ids: Set<String> = []
            for file in files where file.hasSuffix(".probe") {
                let text = (try? String(contentsOfFile: directory + "/" + file, encoding: .utf8)) ?? ""
                ids.formUnion(text.split(separator: "\\n").map(String.init))
            }
            return ids
        }

        private static func readMap(in directory: String) -> [String: [String]]? {
            guard let text = try? String(contentsOfFile: directory + "/map.tsv", encoding: .utf8) else { return nil }
            var reaching: [String: [String]] = [:]
            for line in text.split(separator: "\\n") {
                let fields = line.split(separator: "\\t").map(String.init)
                guard let id = fields.first else { continue }
                reaching[id] = Array(fields.dropFirst())
            }
            return reaching
        }
    }
    """

    /// Adds the driver to the first file of the target that imports Testing.
    ///
    /// Written by replacing the file, never in place.
    static func appendDriver(
        to target: TestedScope.TestTarget,
        source driver: String = Batch.driver,
        named name: String = driverClass
    ) throws {
        guard let file = target.files.first(where: {
            (try? String(contentsOfFile: $0, encoding: .utf8))?.contains("import Testing") == true
        }) else {
            throw DriverFailure(description: "no file in \(target.name) imports Testing")
        }

        let source = try String(contentsOfFile: file, encoding: .utf8)
        guard !source.contains(name) else { return }

        try (source + driver).write(toFile: file, atomically: true, encoding: .utf8)
    }

    public struct DriverFailure: Error, CustomStringConvertible {
        public let description: String
    }
}

extension Batch {
    /// Reads the driver's report as it grows.
    ///
    /// Lines are taken only once they end, so a report caught mid-write is
    /// read again on the next poll rather than half-parsed.
    struct Report {
        let url: URL
        private var offset: UInt64 = 0
        private var pending = ""

        init(url: URL) {
            self.url = url
        }

        mutating func read() -> [Event] {
            lines().compactMap(Self.parse)
        }

        /// The lines written since the last read.
        mutating func lines() -> [String] {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
            defer { try? handle.close() }

            try? handle.seek(toOffset: offset)
            let data = handle.readDataToEndOfFile()
            offset += UInt64(data.count)
            pending += String(decoding: data, as: UTF8.self)

            var lines: [String] = []
            while let newline = pending.firstIndex(of: "\n") {
                lines.append(String(pending[..<newline]))
                pending = String(pending[pending.index(after: newline)...])
            }
            return lines
        }

        static func parse(_ line: String) -> Event? {
            // Tab-separated, since test names have spaces in them.
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            switch fields.first {
            case "TEST" where fields.count == 3:
                return .test(id: fields[1], name: fields[2])
            case "COVERED" where fields.count >= 2:
                return .covered(fields[1], tests: Array(fields.dropFirst(2)))
            case "KILLEDBY" where fields.count >= 2:
                return .killedBy(fields[1], tests: Array(fields.dropFirst(2)))
            case "TIME" where fields.count == 3:
                return TimeInterval(fields[2]).map { .timed(fields[1], seconds: $0) }
            case "ALONE" where fields.count == 2:
                return .failedAlone(fields[1])
            default:
                break
            }

            let words = line.split(separator: " ").map(String.init)

            if words.count == 2, words[0] == "START" {
                return .started(words[1])
            }

            if words.count == 2, words[0] == "REACHED" {
                return .reached(words[1])
            }

            if words.count == 4, words[0] == "END", let duration = TimeInterval(words[3]) {
                switch words[2] {
                case "killed": return .finished(words[1], .killed, duration)
                case "survived": return .finished(words[1], .survived, duration)
                case "nocoverage": return .finished(words[1], .noCoverage, duration)
                case "error": return .finished(words[1], .error, duration)
                default: return nil
                }
            }

            return nil
        }
    }
}
