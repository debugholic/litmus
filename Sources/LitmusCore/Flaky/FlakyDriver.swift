import Foundation

/// What `litmus flaky` adds to a test target: a test that runs the others
/// again and again, in the one process, and writes down how each went.
///
/// Three passes, in this order:
///
/// 1. Each test alone, last listed first, in a process nothing has run in
///    yet. A test that needs another to have run before it fails here,
///    since that one has not run yet.
/// 2. The whole suite, as many times as asked. A test that fails in some
///    runs and not others is flaky.
/// 3. Each test alone again, after all that. A test that fails here though
///    the suite passed depends on state the runs left behind.
///
/// Swift Testing only: its runner can be called again in process, where
/// XCTest's cannot.
public enum FlakyDriver {
    static let driverClass = "__LitmusFlaky"
    static let driverTest = "test__litmus_flaky"
    static let resultsVariable = "LITMUS_FLAKY_RESULTS"
    static let runsVariable = "LITMUS_FLAKY_RUNS"
    /// A file of spans, `File.swift`, first line, last line: only the tests
    /// declared in one run. Without it, every test does.
    static let pickVariable = "LITMUS_FLAKY_PICK"

    /// Whether the driver can run a target's tests, and what it leaves out
    /// when it can: nil to run it, else why not. `note` names XCTest cases
    /// beside the Swift Testing ones, which the driver does not rerun.
    public static func fit(_ target: TestedScope.TestTarget) -> (reason: String?, note: String?) {
        var swiftTesting = false
        var xctest = false
        for file in target.files {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            let own = text.components(separatedBy: Batch.driverMarker).first ?? text
            if own.contains("import Testing") { swiftTesting = true }
            if TestedScope.declaresXCTestCase(in: own) { xctest = true }
        }
        guard swiftTesting else { return ("no Swift Testing tests; litmus flaky reruns those only", nil) }
        return (nil, xctest ? "its XCTest cases are not rerun" : nil)
    }

    /// Appended to one file of the target, after the same marker the mutation
    /// driver uses, so the target is still read as the project wrote it.
    static let source = #"""


    \#(Batch.driverMarker) Never part of your project. ───
    // Runs the tests again and again in this one process, for `litmus flaky`.
    import Foundation
    import Testing
    import XCTest

    final class \#(driverClass): XCTestCase {
        func \#(driverTest)() async throws {
            let environment = ProcessInfo.processInfo.environment
            guard
                let resultsPath = environment["\#(resultsVariable)"],
                let runs = environment["\#(runsVariable)"].flatMap({ Int($0) })
            else { return }

            FileManager.default.createFile(atPath: resultsPath, contents: nil)
            guard let results = FileHandle(forWritingAtPath: resultsPath) else { return }
            defer { try? results.close() }

            func record(_ fields: [String]) {
                let line = fields
                    .map { String($0.map { $0 == "\t" || $0 == "\n" || $0 == "\r" ? " " : $0 }) }
                    .joined(separator: "\t")
                _ = try? results.seekToEnd()
                try? results.write(contentsOf: Data((line + "\n").utf8))
                try? results.synchronize()
            }

            let stream = NSTemporaryDirectory() + "litmus-flaky-\(getpid()).jsonl"

            // Every test, in the order Swift Testing lists them.
            var listing = __CommandLineArguments_v0()
            listing.listTests = true
            listing.eventStreamOutputPath = stream
            listing.eventStreamSchemaVersion = "0"
            try? FileManager.default.removeItem(atPath: stream)
            let _: CInt = await __swiftPMEntryPoint(passing: listing)

            // The tests a change touched, when only those are to run.
            let picks: [(file: String, lines: ClosedRange<Int>)]? = environment["\#(pickVariable)"].map { path in
                ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { line in
                    let fields = line.split(separator: "\t").map(String.init)
                    guard fields.count == 3, let first = Int(fields[1]), let last = Int(fields[2]), first <= last
                    else { return nil }
                    return (fields[0], first...last)
                }
            }
            // `Module.Suite/test()/File.swift:12:5`: the file and the line.
            func picked(_ id: String) -> Bool {
                guard let picks else { return true }
                let place = (id.split(separator: "/").last ?? "").split(separator: ":")
                guard place.count >= 2, let line = Int(place[1]) else { return false }
                return picks.contains { $0.file == place[0] && $0.lines.contains(line) }
            }

            var tests: [String] = []
            for object in Self.records(in: stream) {
                guard
                    object["kind"] as? String == "test",
                    let payload = object["payload"] as? [String: Any],
                    payload["kind"] as? String == "function",
                    let id = payload["id"] as? String,
                    picked(id)
                else { continue }
                tests.append(id)
                record(["TEST", id, (payload["displayName"] as? String) ?? (payload["name"] as? String) ?? id])
            }
            let listed = Set(tests)
            // An empty filter would be no filter, and run everything.
            guard !tests.isEmpty else {
                record(["DONE"])
                return
            }
            let group = picks == nil ? nil : tests.map { NSRegularExpression.escapedPattern(for: $0) }

            // One run: the listed tests that ended, and the ones among them
            // that recorded an issue they did not expect.
            func run(_ filter: [String]?) async -> (ended: [String], failed: Set<String>) {
                var arguments = __CommandLineArguments_v0()
                arguments.parallel = false
                arguments.quiet = true
                arguments.filter = filter
                arguments.eventStreamOutputPath = stream
                arguments.eventStreamSchemaVersion = "0"
                try? FileManager.default.removeItem(atPath: stream)
                let _: CInt = await __swiftPMEntryPoint(passing: arguments)

                var ended: [String] = []
                var failed: Set<String> = []
                for object in Self.records(in: stream) {
                    guard
                        let payload = object["payload"] as? [String: Any],
                        let id = payload["testID"] as? String,
                        listed.contains(id)
                    else { continue }
                    switch payload["kind"] as? String {
                    case "testEnded":
                        if !ended.contains(id) { ended.append(id) }
                    case "issueRecorded":
                        if let issue = payload["issue"] as? [String: Any], issue["isKnown"] as? Bool == true { continue }
                        failed.insert(id)
                    default:
                        break
                    }
                }
                return (ended, failed)
            }

            func pass(_ phase: String, _ index: Int, _ filter: [String]?) async {
                record(["BEGIN", phase, String(index)])
                let started = Date()
                let outcome = await run(filter)
                for id in outcome.ended {
                    record(["RESULT", phase, String(index), outcome.failed.contains(id) ? "fail" : "pass", id])
                }
                record(["END", phase, String(index), String(Date().timeIntervalSince(started))])
            }

            func alone(_ test: String) -> [String] { [NSRegularExpression.escapedPattern(for: test)] }

            for (index, test) in tests.reversed().enumerated() {
                await pass("reverse", index, alone(test))
            }
            for index in 0..<runs {
                await pass("suite", index, group)
            }
            for (index, test) in tests.enumerated() {
                await pass("again", index, alone(test))
            }
            record(["DONE"])
        }

        private static func records(in path: String) -> [[String: Any]] {
            ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
                .split(separator: "\n")
                .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }
    }
    """#
}
