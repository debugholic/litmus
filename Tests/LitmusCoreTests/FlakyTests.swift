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
        #expect(byName["once"]?.reasons == ["passes on its first run, then fails every suite run — a test run before it leaves state behind"])
        #expect(byName["leans"]?.reasons == ["fails every time"])
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
