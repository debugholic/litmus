import Foundation
import Testing

@testable import LitmusCore

/// Rendering had no tests at all, and a mutation run said so: every branch in
/// `Report` survived. The formats are what a person and a CI job actually read,
/// so a silent change here is a change nobody sees until the numbers are wrong.
@Suite("Report")
struct ReportTests {
    private func mutant(
        _ file: String,
        line: Int,
        column: Int = 5,
        description: String
    ) -> Mutant {
        Mutant(
            filePath: "/project/Sources/\(file)",
            line: line,
            column: column,
            utf8Offset: line * 10,
            operator: "ChangeLogicalConnector",
            description: description
        )
    }

    private func summary(_ results: [(String, Int, Verdict)]) -> MutationRun.Summary {
        MutationRun.Summary(
            results: results.map {
                MutantResult(
                    mutant: mutant($0.0, line: $0.1, description: "changed && to ||"),
                    verdict: $0.2,
                    duration: 1
                )
            },
            duration: 12.5
        )
    }

    // MARK: - plain

    @Test("plain states the score and the counts")
    func plainScore() {
        let rendered = try! Report(summary([
            ("A.swift", 10, .killed),
            ("A.swift", 20, .survived),
            ("A.swift", 30, .error),
        ])).rendered(as: .plain)

        // Errors stay out of the ratio, so one killed and one survived is 50%.
        #expect(rendered.contains("Litmus score 50%"))
        #expect(rendered.contains("killed 1 / survived 1 / error 1"))
    }

    @Test("plain lists survivors and leaves killed mutants out")
    func plainSurvivors() {
        let rendered = try! Report(summary([
            ("Killed.swift", 10, .killed),
            ("Survived.swift", 20, .survived),
        ])).rendered(as: .plain)

        #expect(rendered.contains("Survived.swift:20"))
        #expect(!rendered.contains("Killed.swift"))
    }

    @Test("plain says nothing about survivors when there are none")
    func plainNoSurvivors() {
        let rendered = try! Report(summary([("A.swift", 10, .killed)])).rendered(as: .plain)

        #expect(rendered.contains("Litmus score 100%"))
        #expect(!rendered.contains("survived —"))
    }

    @Test("plain reports no score when nothing produced a verdict")
    func plainNoScore() {
        let rendered = try! Report(summary([("A.swift", 10, .error)])).rendered(as: .plain)

        #expect(rendered.contains("Litmus score —"))
    }

    @Test("survivors are ordered by file and then by line")
    func survivorOrder() {
        let rendered = try! Report(summary([
            ("B.swift", 10, .survived),
            ("A.swift", 30, .survived),
            ("A.swift", 20, .survived),
        ])).rendered(as: .plain)

        let order = ["A.swift:20", "A.swift:30", "B.swift:10"]
            .compactMap { rendered.range(of: $0)?.lowerBound }

        #expect(order.count == 3)
        #expect(order == order.sorted())
    }

    // MARK: - xcode

    /// Xcode shows these beside the mutated line. Killed mutants are the good
    /// case; listing them would bury the holes.
    @Test("xcode emits a warning per survivor, with the full path")
    func xcodeWarnings() {
        let rendered = try! Report(summary([
            ("Killed.swift", 10, .killed),
            ("Survived.swift", 20, .survived),
        ])).rendered(as: .xcode)

        #expect(rendered == "/project/Sources/Survived.swift:20:5: "
            + "warning: Litmus: changed && to || — no test failed")
    }

    // MARK: - json

    @Test("json carries the counts and every result")
    func jsonPayload() throws {
        let rendered = try Report(summary([
            ("A.swift", 10, .killed),
            ("A.swift", 20, .survived),
        ])).rendered(as: .json)

        let object = try JSONSerialization.jsonObject(
            with: Data(rendered.utf8)
        ) as? [String: Any]

        #expect(object?["killed"] as? Int == 1)
        #expect(object?["survived"] as? Int == 1)
        #expect(object?["error"] as? Int == 0)
        #expect(object?["score"] as? Double == 50)

        // Every mutant is listed, killed ones included: this is the payload a
        // machine reads, so it carries the whole run rather than the summary.
        let mutants = object?["mutants"] as? [[String: Any]]
        #expect(mutants?.count == 2)
        #expect(mutants?.map { $0["verdict"] as? String } == ["killed", "survived"])
        #expect(mutants?.first?["file"] as? String == "A.swift")
        #expect(mutants?.first?["line"] as? Int == 10)
    }

    // MARK: - html

    @Test("html escapes text that would otherwise close a tag")
    func htmlEscaping() {
        let result = MutantResult(
            mutant: Mutant(
                filePath: "/project/Sources/A.swift",
                line: 10,
                column: 5,
                utf8Offset: 100,
                operator: "RelationalOperatorReplacement",
                description: "changed <= to > & back"
            ),
            verdict: .survived,
            duration: 1
        )

        let rendered = try! Report(
            MutationRun.Summary(results: [result], duration: 1)
        ).rendered(as: .html)

        #expect(rendered.contains("&lt;= to &gt; &amp; back"))
        #expect(!rendered.contains("<= to > & back"))
    }
}
