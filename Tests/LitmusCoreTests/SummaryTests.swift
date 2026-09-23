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
}
