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
        public let built: BuiltTests
        public let testTarget: String
    }

    /// Something the driver reported.
    public enum Event: Sendable, Equatable {
        case started(String)
        case finished(String, Verdict, TimeInterval)
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
    }

    /// The name that stands for "no mutant" in a batch.
    public static let baseline = "-"

    static let batchFileVariable = "LITMUS_BATCH_FILE"
    static let resultsFileVariable = "LITMUS_RESULTS_FILE"
    static let driverClass = "__LitmusDriver"
    static let driverTest = "test__litmus"

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

            FileManager.default.createFile(atPath: resultsPath, contents: nil)
            guard let results = FileHandle(forWritingAtPath: resultsPath) else { return }
            defer { try? results.close() }

            func record(_ line: String) {
                _ = try? results.seekToEnd()
                try? results.write(contentsOf: Data((line + "\\n").utf8))
                try? results.synchronize()
            }

            let arguments = try JSONDecoder().decode(
                __CommandLineArguments_v0.self,
                from: Data(#"{"parallel":false,"quiet":true}"#.utf8)
            )

            for id in batch.split(separator: "\\n").map(String.init) where !id.isEmpty {
                if id == "\(baseline)" {
                    unsetenv("\(MutationSwitch.activeVariable)")
                } else {
                    setenv("\(MutationSwitch.activeVariable)", id, 1)
                }

                record("START \\(id)")
                let started = Date()
                let code: CInt = await __swiftPMEntryPoint(passing: arguments)
                record("END \\(id) \\(code == 0 ? "survived" : "killed") \\(Date().timeIntervalSince(started))")

                // Measured against a failing suite, every mutant looks killed.
                if id == "\(baseline)", code != 0 { break }
            }

            unsetenv("\(MutationSwitch.activeVariable)")
        }
    }
    """

    /// Adds the driver to the first file of the target that imports Testing.
    ///
    /// Written by replacing the file, never in place.
    static func appendDriver(to target: TestedScope.TestTarget) throws {
        guard let file = target.files.first(where: {
            (try? String(contentsOfFile: $0, encoding: .utf8))?.contains("import Testing") == true
        }) else {
            throw DriverFailure(description: "no file in \(target.name) imports Testing")
        }

        let source = try String(contentsOfFile: file, encoding: .utf8)
        guard !source.contains(driverClass) else { return }

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
            guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
            defer { try? handle.close() }

            try? handle.seek(toOffset: offset)
            let data = handle.readDataToEndOfFile()
            offset += UInt64(data.count)
            pending += String(decoding: data, as: UTF8.self)

            var events: [Event] = []
            while let newline = pending.firstIndex(of: "\n") {
                let line = String(pending[..<newline])
                pending = String(pending[pending.index(after: newline)...])
                if let event = Self.parse(line) { events.append(event) }
            }
            return events
        }

        static func parse(_ line: String) -> Event? {
            let words = line.split(separator: " ").map(String.init)

            if words.count == 2, words[0] == "START" {
                return .started(words[1])
            }

            if words.count == 4, words[0] == "END", let duration = TimeInterval(words[3]) {
                switch words[2] {
                case "killed": return .finished(words[1], .killed, duration)
                case "survived": return .finished(words[1], .survived, duration)
                default: return nil
                }
            }

            return nil
        }
    }
}
