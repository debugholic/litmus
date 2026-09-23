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
}
