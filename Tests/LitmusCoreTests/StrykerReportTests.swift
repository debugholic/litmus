import Foundation
import Testing

@testable import LitmusCore

/// The report in Stryker's schema, read by Stryker's viewer.
@Suite("Stryker report")
struct StrykerReportTests {
    /// An original project and a working copy with a different file at the
    /// same path, so reading the wrong one shows.
    private final class Trees {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("litmus-stryker-\(UUID().uuidString)")
        var project: URL { base.appendingPathComponent("Project") }
        var copy: URL { base.appendingPathComponent("Copy") }

        init(original: String) throws {
            for (root, text) in [(project, original), (copy, "// injected\n" + original)] {
                let file = root.appendingPathComponent("Sources/A.swift")
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try text.write(to: file, atomically: true, encoding: .utf8)
            }
        }

        deinit { try? FileManager.default.removeItem(at: base) }
    }

    private func report(_ trees: Trees, _ verdict: Verdict, column: Int = 13) throws -> [String: Any] {
        let result = MutantResult(
            mutant: Mutant(
                filePath: trees.copy.appendingPathComponent("Sources/A.swift").path,
                line: 1, column: column, utf8Offset: 12,
                operator: "RelationalOperatorReplacement", description: "changed == to !=",
                change: Change(
                    startLine: 1, startColumn: column - 2, endLine: 1, endColumn: column + 4,
                    original: "a == b", replacement: "a != b", function: "f()"
                )
            ),
            verdict: verdict,
            duration: 0
        )
        let json = try StrykerReport(
            MutationRun.Summary(results: [result], duration: 0),
            workingCopy: trees.copy,
            project: trees.project
        ).json()
        return try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func onlyMutant(_ root: [String: Any]) throws -> [String: Any] {
        let files = try #require(root["files"] as? [String: [String: Any]])
        let file = try #require(files["Sources/A.swift"])
        return try #require((file["mutants"] as? [[String: Any]])?.first)
    }

    @Test("shows the original source under its path in the project")
    func source() throws {
        let trees = try Trees(original: "let x = a == b\n")
        let root = try report(trees, .survived)

        let files = try #require(root["files"] as? [String: [String: Any]])
        #expect(files["Sources/A.swift"]?["source"] as? String == "let x = a == b\n")
        #expect(root["schemaVersion"] as? String == "2")
    }

    /// The working copy's path came back from the file walk as /private/tmp
    /// and from the caller as /tmp, and the report showed the mutated copy.
    @Test("finds the original through a symlinked path")
    func symlinkedPaths() throws {
        let trees = try Trees(original: "let x = a == b\n")
        let linked = trees.base.appendingPathComponent("Link")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: trees.copy)

        let result = MutantResult(
            mutant: Mutant(
                filePath: linked.appendingPathComponent("Sources/A.swift").path,
                line: 1, column: 11, utf8Offset: 10,
                operator: "RelationalOperatorReplacement", description: "changed == to !="
            ),
            verdict: .survived,
            duration: 0
        )
        let json = try StrykerReport(
            MutationRun.Summary(results: [result], duration: 0),
            workingCopy: trees.copy,
            project: trees.project
        ).json()

        #expect(json.contains("\"Sources/A.swift\""))
        #expect(!json.contains("injected"))
    }

    @Test("puts the mutant where the change is, with what it becomes")
    func location() throws {
        let trees = try Trees(original: "let x = a == b\n")
        let mutant = try onlyMutant(try report(trees, .survived, column: 11))

        #expect(mutant["replacement"] as? String == "a != b")
        let location = try #require(mutant["location"] as? [String: [String: Int]])
        #expect(location["start"] == ["line": 1, "column": 9])
        #expect(location["end"] == ["line": 1, "column": 15])
        #expect((mutant["description"] as? String)?.hasPrefix("[comparison]") == true)
        #expect(mutant["statusReason"] as? String == GapKind.comparison.hint)
    }

    @Test("maps every verdict to a status the viewer knows")
    func statuses() {
        #expect(StrykerReport.status(.killed) == "Killed")
        #expect(StrykerReport.status(.survived) == "Survived")
        #expect(StrykerReport.status(.timedOut) == "Timeout")
        #expect(StrykerReport.status(.unviable) == "CompileError")
        #expect(StrykerReport.status(.error) == "RuntimeError")
    }

    /// SwiftSyntax columns are UTF-8 bytes; the viewer's are characters.
    @Test("counts columns in characters on a line with Korean on it")
    func koreanColumns() {
        let lines = ["let 이름 = a == b"]
        // "let 이름 = " is 4 + 6 + 3 = 13 bytes but 9 characters.
        #expect(StrykerReport.column(14, onLine: 1, of: lines) == 10)
        #expect(StrykerReport.column(3, onLine: 1, of: lines) == 3)
    }

    @Test("names the tests that passed through a mutant and the ones that caught it")
    func tests() throws {
        let trees = try Trees(original: "let x = a == b\n")
        let reaching = TestRef(id: "App.T/a()/ATests.swift:3:5", name: "빈 값이면 거른다")
        let catching = TestRef(id: "App.T/b()/ATests.swift:9:5", name: "b()")
        var result = MutantResult(
            mutant: Mutant(
                filePath: trees.copy.appendingPathComponent("Sources/A.swift").path,
                line: 1, column: 11, utf8Offset: 10,
                operator: "RelationalOperatorReplacement", description: "changed == to !="
            ),
            verdict: .killed,
            duration: 0
        )
        result.coveredBy = [reaching, catching]
        result.killedBy = [catching]

        let json = try StrykerReport(
            MutationRun.Summary(results: [result], duration: 0), workingCopy: trees.copy, project: trees.project
        ).json()
        let root = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let mutant = try onlyMutant(root)

        #expect(mutant["coveredBy"] as? [String] == [reaching.id, catching.id])
        #expect(mutant["killedBy"] as? [String] == [catching.id])

        let testFiles = try #require(root["testFiles"] as? [String: [String: Any]])
        let listed = try #require(testFiles["ATests.swift"]?["tests"] as? [[String: String]])
        #expect(listed == [["id": reaching.id, "name": "빈 값이면 거른다"], ["id": catching.id, "name": "b()"]])
    }

    // MARK: - what to read first

    private func front(_ results: [MutantResult], copy: URL) -> String {
        StrykerReport(MutationRun.Summary(results: results, duration: 0), workingCopy: copy, project: copy).front()
    }

    private func result(_ verdict: Verdict, at path: String, line: Int = 1) -> MutantResult {
        MutantResult(
            mutant: Mutant(
                filePath: path, line: line, column: 1, utf8Offset: line,
                operator: "RelationalOperatorReplacement", description: "changed == to !=",
                change: Change(
                    startLine: line, startColumn: 1, endLine: line, endColumn: 7,
                    original: "a == b", replacement: "a != b", function: "f()"
                )
            ),
            verdict: verdict,
            duration: 0
        )
    }

    /// The viewer names files under the folder they all share; a link that
    /// kept it opened nothing.
    @Test("links under the folder every file shares, as the viewer routes them")
    func frontLinksDropSharedFolder() {
        let copy = URL(fileURLWithPath: "/tmp/copy")
        let html = front([
            result(.noCoverage, at: "/tmp/copy/Sources/Shared/UI/KernButton.swift"),
            result(.noCoverage, at: "/tmp/copy/Sources/Feature/A.swift"),
        ], copy: copy)

        #expect(html.contains("href=\"#mutant/Shared/UI/KernButton.swift\""))
        #expect(!html.contains("#mutant/Sources/"))
    }

    @Test("draws no bar when the tests reach nothing, rather than a red one")
    func frontNothingReached() {
        let copy = URL(fileURLWithPath: "/tmp/copy")
        let html = front([result(.noCoverage, at: "/tmp/copy/A.swift")], copy: copy)

        #expect(!html.contains("class=\"bar\""))
        #expect(html.contains("No test reaches"))
    }

    @Test("links to the file in the viewer, with the path encoded and names escaped")
    func frontLinks() {
        let copy = URL(fileURLWithPath: "/tmp/copy")
        var survivor = result(.survived, at: "/tmp/copy/Feature Flags/Toggle#2.swift")
        survivor.coveredBy = [TestRef(id: "App.T/a()/T.swift:1:1", name: "값이 <비면> 거른다")]
        let html = front([survivor, result(.killed, at: "/tmp/copy/B.swift")], copy: copy)

        #expect(html.contains("href=\"#mutant/Feature%20Flags/Toggle%232.swift\""))
        #expect(html.contains("값이 &lt;비면&gt; 거른다"))
        #expect(html.contains("class=\"bar\""))
    }
}
