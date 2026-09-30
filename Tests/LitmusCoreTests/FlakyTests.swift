import Foundation
import SwiftParser
import Testing

@testable import LitmusCore

@Suite("Flaky")
struct FlakyTests {
    private func run(_ lines: [String]) -> FlakyRun {
        var run = FlakyRun(target: "AppTests")
        lines.forEach { run.read($0) }
        return run
    }

    private let listing = [
        "TEST\tApp.T/steady()/T.swift:3:2\tsteady",
        "TEST\tApp.T/sometimes()/T.swift:6:2\t가끔 실패한다",
        "TEST\tApp.T/leans()/T.swift:9:2\tleans",
        "TEST\tApp.T/once()/T.swift:12:2\tonce",
    ]

    private func pass(_ phase: String, _ index: Int, _ results: [(String, Bool)]) -> [String] {
        ["BEGIN\t\(phase)\t\(index)"]
            + results.map { "RESULT\t\(phase)\t\(index)\t\($0.1 ? "pass" : "fail")\tApp.T/\($0.0)()/T.swift:\(["steady": 3, "sometimes": 6, "leans": 9, "once": 12][$0.0]!):2" }
            + ["END\t\(phase)\t\(index)\t0.5"]
    }

    @Test("writes a driver that parses as Swift")
    func driverParses() {
        #expect(!Parser.parse(source: "import Testing\n" + FlakyDriver.source).hasError)
        #expect(FlakyDriver.source.contains(Batch.driverMarker))
    }

    @Test("tells a flaky test, one that needs another first, and one that fails when run again")
    func verdicts() {
        var lines = listing
        // Last first, before anything else: leans() has nothing to lean on.
        lines += pass("reverse", 0, [("once", true)])
        lines += pass("reverse", 1, [("leans", false)])
        lines += pass("reverse", 2, [("sometimes", true)])
        lines += pass("reverse", 3, [("steady", true)])
        for index in 0..<4 {
            lines += pass("suite", index, [("steady", true), ("sometimes", index != 2), ("leans", true), ("once", true)])
        }
        lines += pass("again", 0, [("steady", true)])
        lines += pass("again", 1, [("sometimes", true)])
        lines += pass("again", 2, [("leans", true)])
        lines += pass("again", 3, [("once", false)])
        lines.append("DONE")

        let byName = Dictionary(uniqueKeysWithValues: run(lines).verdicts.map { ($0.name, $0) })

        #expect(byName["steady"]?.isStable == true)
        #expect(byName["가끔 실패한다"]?.reasons == ["fails 1 of 4 suite runs"])
        #expect(byName["leans"]?.reasons == ["fails unless a test listed before it runs first"])
        #expect(byName["once"]?.reasons == ["fails when run again on its own, after the suite"])
        #expect(run(lines).suiteRuns == 4)
        #expect(run(Array(lines.prefix(listing.count + 6))).progress(of: 4) == "alone 2/4")
        #expect(run(lines).finished)
    }

    /// After a failing suite run, failing alone says nothing new.
    @Test("reads failing alone only against a suite that always passed")
    func aloneNeedsSteadySuite() {
        var lines = listing
        lines += pass("reverse", 0, [("once", false)])
        lines += pass("suite", 0, [("once", false)])
        lines += pass("suite", 1, [("once", true)])
        lines += pass("again", 0, [("once", false)])

        let once = run(lines).verdicts.first { $0.name == "once" }
        #expect(once?.reasons == ["fails 1 of 2 suite runs"])
    }

    /// The first pass runs each test alone before the suite. A test that
    /// passes only the first time passes there and fails in every suite
    /// run after it; that is not a test that always fails.
    @Test("tells a test that passes only first from one that always fails")
    func passesFirstOnly() {
        var lines = listing
        lines += pass("reverse", 0, [("once", true)])
        lines += pass("reverse", 1, [("leans", false)])
        for index in 0..<3 {
            lines += pass("suite", index, [("once", false), ("leans", false)])
        }

        let byName = Dictionary(uniqueKeysWithValues: run(lines).verdicts.map { ($0.name, $0) })
        #expect(byName["once"]?.reasons == ["passes on its first run, then fails every one of the suite runs — a test run before it leaves state behind"])
        #expect(byName["leans"]?.reasons == ["fails every time"])
    }

    @Test("says so when a test did not end in every suite run")
    func missingRuns() {
        var lines = listing
        lines += pass("suite", 0, [("steady", true), ("once", true)])
        lines += pass("suite", 1, [("once", true)])

        let byName = Dictionary(uniqueKeysWithValues: run(lines).verdicts.map { ($0.name, $0) })
        #expect(byName["steady"]?.reasons == ["ended in only 1 of 2 suite runs"])
        #expect(byName["once"]?.isStable == true)
    }

    private let testFile = """
    import Testing

    func helper() -> Int { 1 }

    @Suite struct T {
        @Test("first")
        func first() { #expect(helper() == 1) }

        @Test func second() {
            #expect(true)
        }
    }
    """

    @Test("picks the test function a changed line is in, attributes and all")
    func picksChangedTest() {
        #expect(ChangedTests.spans(in: testFile, changed: [10]) == [9...11])
        #expect(ChangedTests.spans(in: testFile, changed: [7, 8]) == [6...7])
    }

    /// A helper or a suite's set-up may be what every test there leans on.
    @Test("picks the whole file for a change outside any test, and nothing for a blank line")
    func picksFile() {
        #expect(ChangedTests.spans(in: testFile, changed: [3]) == [1...12])
        #expect(ChangedTests.spans(in: testFile, changed: [2]).isEmpty)
    }

    /// A comment above a new test picked every test in the file.
    @Test("picks nothing for a comment")
    func ignoresComments() {
        let source = testFile + "\n\n// New, and fails now and then.\n@Test func third() {}\n"
        #expect(ChangedTests.spans(in: source, changed: [14, 15]) == [15...15])
        #expect(ChangedTests.spans(in: source, changed: [14]).isEmpty)
    }

    @Test("says runs together, not suite runs, when only changed tests ran")
    func groupedWording() {
        var lines = listing
        lines += pass("suite", 0, [("once", true)])
        lines += pass("suite", 1, [("once", false)])
        var grouped = FlakyRun(target: "AppTests")
        grouped.grouped = true
        lines.forEach { grouped.read($0) }

        #expect(grouped.verdicts.first { $0.name == "once" }?.reasons == ["fails 1 of 2 runs together"])
    }

    @Test("names the test a lone pass stopped in")
    func stoppedIn() {
        var lines = listing
        lines += ["BEGIN\treverse\t1"]
        var stopped = run(lines)
        stopped.stop = FlakyRun.Stop(phase: .reverse, index: 1, hung: false)

        #expect(stopped.stoppedIn == "App.T/leans()/T.swift:9:2")
        #expect(stopped.verdicts.first { $0.name == "leans" }?.reasons == ["took the process down when run on its own"])
    }

    /// The spread says whether runs slow down as they pile up in one process.
    @Test("says where the time went: launch, the lone passes, and each suite run")
    func timing() throws {
        var lines = listing
        lines += ["BEGIN\treverse\t0", "END\treverse\t0\t10", "BEGIN\treverse\t1", "END\treverse\t1\t20"]
        for (index, seconds) in [1.5, 2.5, 5.0].enumerated() {
            lines += ["BEGIN\tsuite\t\(index)", "END\tsuite\t\(index)\t\(seconds)"]
        }
        lines += ["BEGIN\tagain\t0", "END\tagain\t0\t25"]
        var timed = run(lines)
        timed.launch = 105

        #expect(FlakyReport.timing(timed) == ["launch 1m 45s", "alone 30s", "suite 3 × 3.0s (1.5s–5.0s)", "alone again 25s"])
        timed.read("BEGIN\tagain\t1")
        timed.read("END\tagain\t1\t0.3")
        #expect(FlakyReport.timing(timed).last == "alone again 25s")
        #expect(try FlakyReport(runs: [timed], asked: 3, build: 40, duration: 240).rendered(as: .plain)
            .contains("took 4m 0s — build 40s, launch 1m 45s, alone 30s, suite 3 × 3.0s (1.5s–5.0s), alone again 25s"))
    }

    @Test("reports the unstable tests, and what was left out")
    func report() throws {
        var lines = listing
        for index in 0..<2 {
            lines += pass("suite", index, [("steady", true), ("sometimes", index == 0)])
        }
        let report = FlakyReport(
            runs: [run(lines)], skipped: [("UITests", "no Swift Testing tests; litmus flaky reruns those only")], asked: 2
        )

        let plain = try report.rendered(as: .plain)
        #expect(plain.contains("1 test(s) not stable:"))
        #expect(plain.contains("  가끔 실패한다  fails 1 of 2 suite runs  (T.swift)"))
        #expect(plain.contains("left out UITests — no Swift Testing tests"))

        let json = try #require(
            JSONSerialization.jsonObject(with: Data(try report.rendered(as: .json).utf8)) as? [String: Any]
        )
        #expect(json["unstable"] as? Int == 1)
        let tests = try #require(((json["targets"] as? [[String: Any]])?.first?["tests"]) as? [[String: Any]])
        #expect(tests.first { $0["name"] as? String == "가끔 실패한다" }?["failed"] as? Int == 1)
    }
}
