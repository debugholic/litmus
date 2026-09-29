import Foundation
import Testing

@testable import LitmusCore

@Suite("Score")
struct SummaryScoreTests {
    private func result(_ verdict: Verdict) -> MutantResult {
        MutantResult(
            mutant: Mutant(
                filePath: "/tmp/A.swift",
                line: 1, column: 1, utf8Offset: 0,
                operator: "ChangeLogicalConnector",
                description: "changed && to ||"
            ),
            verdict: verdict,
            duration: 0
        )
    }

    private func summary(_ verdicts: [Verdict]) -> MutationRun.Summary {
        MutationRun.Summary(results: verdicts.map(result), duration: 0)
    }

    /// The same definitions another report uses: test strength over what the
    /// tests reach, mutation score over everything that ran.
    @Test("counts a mutant no test reaches in the mutation score, not the test strength")
    func twoMeasures() {
        let run = summary([.killed, .timedOut, .survived, .noCoverage, .noCoverage, .noCoverage, .unviable, .error])

        #expect(run.testStrength.map { ($0 * 100).rounded() / 100 } == 66.67)
        #expect(run.mutationScore == 2.0 / 6.0 * 100)
        #expect(summary([.unviable]).mutationScore == nil)
    }

    @Test("says which score falls under its threshold")
    func shortfalls() {
        let run = summary([.killed, .survived, .noCoverage, .noCoverage])

        #expect(run.shortfalls(testStrength: 60, mutationScore: nil) == ["Litmus score 50% is under 60%"])
        #expect(run.shortfalls(testStrength: 50, mutationScore: 30) == ["mutation score 25% is under 30%"])
        #expect(run.shortfalls(testStrength: nil, mutationScore: nil).isEmpty)
        // Nothing the tests reach: nothing to judge.
        #expect(summary([.noCoverage]).shortfalls(testStrength: 80, mutationScore: nil).isEmpty)
    }

    @Test("is killed over killed plus survived")
    func ratio() {
        #expect(summary([.killed, .survived]).score == 50)
        #expect(summary([.killed, .killed]).score == 100)
        #expect(summary([.survived, .survived]).score == 0)
    }

    /// Mutants that could not build carry no information about the tests, so
    /// folding them into either side would misreport the suite.
    @Test("leaves errors out of the ratio")
    func errorsAreExcluded() {
        #expect(summary([.killed, .survived, .error]).score == 50)
        #expect(summary([.killed, .error, .error]).score == 100)
    }

    @Test("is nil when nothing produced a verdict")
    func noVerdicts() {
        #expect(summary([.error, .error]).score == nil)
        #expect(summary([]).score == nil)
    }

    @Test("counts each verdict separately")
    func counts() {
        let summary = summary([.killed, .killed, .survived, .error])

        #expect(summary.killed == 2)
        #expect(summary.survived == 1)
        #expect(summary.errored == 1)
    }

    @Test("counts a timeout as caught and leaves unviable mutants out")
    func timeoutAndUnviable() {
        let summary = summary([.killed, .timedOut, .survived, .unviable])

        #expect(summary.timedOut == 1)
        #expect(summary.unviable == 1)
        #expect(abs((summary.score ?? 0) - 200.0 / 3) < 0.000_1)
    }

    @Test("finds the directory every file shares")
    func commonDirectory() {
        #expect(MutationRun.Summary.commonDirectory(of: ["/p/A/x.swift", "/p/B/y.swift"]) == "/p/")
        #expect(MutationRun.Summary.commonDirectory(of: ["/p/A/x.swift", "/p/A/y.swift"]) == "/p/A/")
        #expect(MutationRun.Summary.commonDirectory(of: []) == "")
    }

    private func result(_ verdict: Verdict, at path: String) -> MutantResult {
        MutantResult(
            mutant: Mutant(
                filePath: path, line: 1, column: 1, utf8Offset: 0,
                operator: "ChangeLogicalConnector", description: "changed && to ||"
            ),
            verdict: verdict,
            duration: 0
        )
    }

    @Test("scores each module when the build named more than one")
    func areasByModule() {
        var run = MutationRun.Summary(results: [
            result(.killed, at: "/p/Features/Login/Sources/A.swift"),
            result(.survived, at: "/p/Features/Login/Sources/B.swift"),
            result(.survived, at: "/p/Core/Network/Sources/C.swift"),
        ], duration: 0)
        run.modules = [
            "/p/Features/Login/Sources/A.swift": "FeatureLogin",
            "/p/Features/Login/Sources/B.swift": "FeatureLogin",
            "/p/Core/Network/Sources/C.swift": "CoreNetwork",
        ]

        #expect(run.areasAreModules)
        #expect(run.areas.map(\.name) == ["CoreNetwork", "FeatureLogin"])
        #expect(run.areas.map(\.score) == [0, 50])
    }

    /// One row for one module says nothing; its folders do.
    @Test("scores each top-level folder when everything is one module")
    func areasByFolder() {
        var run = MutationRun.Summary(results: [
            result(.killed, at: "/p/Sources/Domain/A.swift"),
            result(.noCoverage, at: "/p/Sources/Feature/B.swift"),
            result(.survived, at: "/p/Sources/Feature/C.swift"),
            result(.killed, at: "/p/Sources/Root.swift"),
        ], duration: 0)
        run.modules = Dictionary(uniqueKeysWithValues: run.results.map { ($0.mutant.filePath, "App") })

        #expect(!run.areasAreModules)
        #expect(Set(run.areas.map(\.name)) == ["Domain", "Feature", "(root)"])
        #expect(run.areas.first?.name == "Feature")
    }

    @Test("plain report puts the area table above the file table")
    func plainAreas() throws {
        let run = MutationRun.Summary(results: [
            result(.killed, at: "/p/Sources/Domain/A.swift"),
            result(.survived, at: "/p/Sources/Feature/B.swift"),
        ], duration: 0)
        let rendered = try Report(run).rendered(as: .plain)

        #expect(rendered.contains("by folder, weakest first:"))
        let area = try #require(rendered.range(of: "by folder"))
        let file = try #require(rendered.range(of: "by file"))
        #expect(area.lowerBound < file.lowerBound)
    }

    // MARK: - run info

    private var runInfo: RunInfo {
        RunInfo(
            date: Date(timeIntervalSince1970: 0), commit: "a1b2c3d", branch: "main", version: "0.4.0",
            operators: ["NegateCondition"], harness: "xcode, scheme App, 1 simulator"
        )
    }

    @Test("says how long each part of the run took, and what it ran on")
    func tookAndRun() throws {
        var run = summary([.killed, .survived])
        run = MutationRun.Summary(results: run.results, duration: 748)
        run.phases = MutationRun.Phases(build: 65, baseline: 40)

        let rendered = try Report(run, run: runInfo).rendered(as: .plain)

        #expect(rendered.contains("took 12m 28s — build 1m 5s, launch and baseline 40s, mutants 10m 43s"))
        #expect(rendered.contains("a1b2c3d on main · litmus 0.4.0 · xcode, scheme App, 1 simulator"))
        #expect(Report.duration(3700) == "1h 1m")
        #expect(Report.duration(9) == "9s")
    }

    @Test("puts the run and its phases in the JSON and Stryker reports")
    func runInReports() throws {
        var run = MutationRun.Summary(results: summary([.killed]).results, duration: 100)
        run.phases = MutationRun.Phases(build: 10, baseline: 20)

        let json = try #require(
            JSONSerialization.jsonObject(with: Data(try Report(run, run: runInfo).rendered(as: .json).utf8)) as? [String: Any]
        )
        let info = try #require(json["run"] as? [String: Any])
        #expect(info["commit"] as? String == "a1b2c3d")
        #expect(info["mutants"] as? Double == 70)

        let stryker = try #require(
            JSONSerialization.jsonObject(with: Data(try Report(run, run: runInfo).rendered(as: .stryker).utf8)) as? [String: Any]
        )
        #expect((stryker["framework"] as? [String: Any])?["version"] as? String == "0.4.0")
        #expect(stryker["performance"] as? [String: Int] == ["setup": 10000, "initialRun": 20000, "mutation": 70000])
    }
}
