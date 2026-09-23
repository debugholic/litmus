import Foundation
import Testing

@testable import LitmusCore

/// Reading survivors as what the tests are missing.
@Suite("Gaps")
struct GapTests {
    private func result(
        _ line: Int,
        _ verdict: Verdict,
        in function: String?,
        operator name: String = "RelationalOperatorReplacement",
        description: String = "changed == to !=",
        file: String = "/p/A.swift"
    ) -> MutantResult {
        MutantResult(
            mutant: Mutant(
                filePath: file, line: line, column: 1, utf8Offset: line,
                operator: name, description: description,
                change: Change(
                    startLine: line, startColumn: 1, endLine: line, endColumn: 9,
                    original: "a == b", replacement: "a != b", function: function
                )
            ),
            verdict: verdict,
            duration: 0
        )
    }

    @Test("calls a function untested when none of its mutants were caught")
    func untested() throws {
        let gaps = FunctionGap.find(in: [
            result(1, .survived, in: "A.tap(for:)"),
            result(2, .survived, in: "A.tap(for:)"),
        ])

        let gap = try #require(gaps.first)
        #expect(gap.status == .untested)
        #expect(gap.name == "A.tap(for:)")
        #expect(gap.survivors.count == 2)
    }

    @Test("calls it partly tested when some were caught")
    func partial() throws {
        let gap = try #require(FunctionGap.find(in: [
            result(1, .killed, in: "A.make()"),
            result(2, .timedOut, in: "A.make()"),
            result(3, .survived, in: "A.make()"),
        ]).first)

        #expect(gap.status == .partial)
        #expect(gap.caught == 2)
        #expect(gap.scored == 3)
    }

    @Test("leaves out functions with nothing surviving, and lists untested ones first")
    func ordering() {
        let gaps = FunctionGap.find(in: [
            result(1, .killed, in: "A.solid()"),
            result(2, .killed, in: "A.partly()"),
            result(3, .survived, in: "A.partly()"),
            result(4, .survived, in: "A.never()"),
        ])

        #expect(gaps.map(\.name) == ["A.never()", "A.partly()"])
    }

    @Test("keeps functions of the same name in different files apart")
    func perFile() {
        let gaps = FunctionGap.find(in: [
            result(1, .survived, in: "load()", file: "/p/A.swift"),
            result(1, .survived, in: "load()", file: "/p/B.swift"),
        ])

        #expect(gaps.count == 2)
    }

    @Test("names what a survivor says is missing")
    func kinds() {
        func kind(_ name: String, _ description: String) -> GapKind {
            result(1, .survived, in: nil, operator: name, description: description).mutant.gapKind
        }

        #expect(kind("RelationalOperatorReplacement", "changed == to !=") == .comparison)
        #expect(kind("RelationalOperatorReplacement", "changed < to >=") == .boundary)
        #expect(kind("NegateCondition", "negated the condition") == .branch)
        #expect(kind("SwapTernary", "swapped the branches of a ternary") == .branch)
        #expect(kind("ChangeLogicalConnector", "changed && to ||") == .branch)
        #expect(kind("RemoveSideEffects", "removed the call to f()") == .sideEffect)
        #expect(kind("ChangeArithmeticOperator", "changed + to -") == .value)
        #expect(kind("FlipBooleanLiteral", "changed true to false") == .value)
        #expect(GapKind.sideEffect.rawValue == "side-effect")
    }

    @Test("plain report groups survivors under their function, with the kind and the change")
    func plain() {
        let rendered = try! Report(MutationRun.Summary(results: [
            result(163, .survived, in: "GameResult.handleRowTap(for:)"),
            result(170, .killed, in: "GameResult.other()"),
        ], duration: 1)).rendered(as: .plain)

        #expect(rendered.contains("what to test — 1 untested, 0 partly tested:"))
        #expect(rendered.contains("UNTESTED GameResult.handleRowTap(for:)  0 of 1 caught"))
        #expect(rendered.contains("A.swift:163  comparison   `a == b` → `a != b`"))
    }
}
