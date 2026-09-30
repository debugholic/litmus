import Foundation
import Testing

@testable import LitmusCore

@Suite("GitHub Actions")
struct GitHubActionsTests {
    @Test("is on only where Actions says so")
    func current() {
        #expect(GitHubActions.current([:]) == nil)
        let step = GitHubActions.current([
            "GITHUB_ACTIONS": "true", "GITHUB_STEP_SUMMARY": "/tmp/summary.md", "GITHUB_WORKSPACE": "/work",
        ])
        #expect(step?.summary?.path == "/tmp/summary.md")
        #expect(step?.workspace.path == "/work")
    }

    /// A colon or comma in a title would end the property; a line break the
    /// command.
    @Test("escapes what would end an annotation early")
    func escapes() {
        #expect(GitHubActions.annotation(.warning, file: "A.swift", line: 3, title: "a: b, c", message: "50%\nnext")
            == "::warning file=A.swift,line=3,title=a%3A b%2C c::50%25%0Anext")
    }

    @Test("adds to the summary a step already wrote")
    func appends() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("summary-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: file) }
        let step = GitHubActions.Step(summary: file, workspace: URL(fileURLWithPath: "/"))

        try GitHubActions.append("first", to: step)
        try GitHubActions.append("second", to: step)

        #expect(try String(contentsOf: file, encoding: .utf8) == "first\nsecond\n")
    }

    private func survivor(_ path: String, line: Int, function: String, killedToo: Bool = false) -> [MutantResult] {
        func result(_ verdict: Verdict) -> MutantResult {
            MutantResult(
                mutant: Mutant(
                    filePath: path, line: line, column: 5, utf8Offset: line * 10,
                    operator: "RelationalOperatorReplacement", description: "changed < to >=",
                    change: Change(
                        startLine: line, startColumn: 5, endLine: line, endColumn: 10,
                        original: "a < b", replacement: "a >= b", function: function
                    )
                ),
                verdict: verdict,
                duration: 0
            )
        }
        return killedToo ? [result(.survived), result(.killed)] : [result(.survived)]
    }

    /// The mutants sit in the working copy; the pull request has the files
    /// where the project is, under the checkout.
    @Test("summarises a run and annotates survivors where the checkout has them, untested first")
    func runReport() {
        let copy = "/tmp/litmus/App-1"
        let results = survivor("\(copy)/Sources/Cart.swift", line: 12, function: "Cart.total()", killedToo: true)
            + survivor("\(copy)/Sources/Coupon.swift", line: 4, function: "Coupon.apply()")
        let run = MutationRun.Summary(results: results, duration: 10)
        let report = Report(run, workingCopy: URL(fileURLWithPath: copy), project: URL(fileURLWithPath: "/work/App"))

        let github = report.github(workspace: URL(fileURLWithPath: "/work"))

        #expect(github.summary.hasPrefix("### Litmus score 33%"))
        #expect(github.summary.contains("| `Coupon.swift:4` Coupon.apply() | UNTESTED | `a < b` → `a >= b` | add a case where the two sides are equal |"))
        #expect(github.annotations.count == 2)
        #expect(github.annotations.first?.hasPrefix("::warning file=App/Sources/Coupon.swift,line=4,title=No test noticed this change (UNTESTED Coupon.apply())") == true)
        #expect(github.annotations.first?.hasSuffix("::a < b → a >= b — add a case where the two sides are equal") == true)
    }

    @Test("summarises a flaky run and marks each unstable test where it is declared")
    func flakyReport() throws {
        var run = FlakyRun(target: "AppTests")
        [
            "TEST\tApp.T/sometimes()/FeedTests.swift:9:6\tsometimes",
            "BEGIN\tsuite\t0", "RESULT\tsuite\t0\tpass\tApp.T/sometimes()/FeedTests.swift:9:6", "END\tsuite\t0\t0.1",
            "BEGIN\tsuite\t1", "RESULT\tsuite\t1\tfail\tApp.T/sometimes()/FeedTests.swift:9:6", "END\tsuite\t1\t0.1",
        ].forEach { run.read($0) }
        run.grouped = true
        let report = FlakyReport(runs: [run], asked: 2, scope: "changed since origin/main", calm: ["pure()"])

        let github = report.github(
            files: ["FeedTests.swift": "/work/App/Tests/FeedTests.swift"], workspace: URL(fileURLWithPath: "/work")
        )

        #expect(github.summary.hasPrefix("### litmus flaky: 1 test(s) not stable"))
        #expect(github.summary.contains("| sometimes | fails 1 of 2 runs together | FeedTests.swift |"))
        #expect(github.summary.contains("Left out 1 changed test(s)"))
        #expect(github.annotations == [
            "::error file=App/Tests/FeedTests.swift,line=9,title=Not stable%3A sometimes::fails 1 of 2 runs together",
        ])
    }
}
