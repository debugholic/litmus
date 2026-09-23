import Foundation
import Testing

@testable import LitmusCore

/// Taking out the mutants a build rejected, on a real injected copy.
@Suite("Build repair")
struct BuildRepairTests {
    private static let source = """
    func f(_ a: Int, _ b: Int) -> Bool {
        let first = a < b
        let second = a == b
        return first && second
    }
    """

    /// An original with one file, and its injected working copy.
    private final class Injected {
        let project: URL
        let copy: URL
        let mutants: [Mutant]

        init(_ source: String) throws {
            let base = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("litmus-repair-\(UUID().uuidString)")
            project = base.appendingPathComponent("Project")
            copy = base.appendingPathComponent("Copy")

            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try source.write(
                to: project.appendingPathComponent("Sample.swift"), atomically: true, encoding: .utf8
            )
            mutants = try ProjectInjection()(project: project, workingCopy: copy).mutants
        }

        deinit {
            try? FileManager.default.removeItem(at: project.deletingLastPathComponent())
        }

        var file: String { copy.appendingPathComponent("Sample.swift").path }
        var text: String { (try? String(contentsOfFile: file, encoding: .utf8)) ?? "" }

        func lineNumber(containing mutant: Mutant) -> Int {
            let flag = MutationSwitch.flagName(mutant.switchName)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            return (lines.firstIndex { $0.contains(flag) && !$0.contains("private var") } ?? 0) + 1
        }

        func repair(_ log: String) throws -> [Mutant] {
            try BuildRepair(project: project, workingCopy: copy)(log: log, mutants: mutants)
        }
    }

    @Test("takes out the mutant on the line the compiler named, and keeps the rest")
    func namedLine() throws {
        let injected = try Injected(Self.source)
        let rejected = try #require(injected.mutants.first { $0.description.contains("<") })
        let line = injected.lineNumber(containing: rejected)

        let pulled = try injected.repair("\(injected.file):\(line):20: error: binary operator '>=' cannot be applied")

        #expect(pulled == [rejected])
        #expect(!injected.text.contains(MutationSwitch.flagName(rejected.switchName)))
        for kept in injected.mutants where kept != rejected {
            #expect(injected.text.contains(MutationSwitch.flagName(kept.switchName)))
        }
    }

    @Test("takes out the whole file when the line has no switch on it")
    func unnamedLine() throws {
        let injected = try Injected(Self.source)

        let pulled = try injected.repair("\(injected.file):1:1: error: something further down broke")

        #expect(Set(pulled.map(\.switchName)) == Set(injected.mutants.map(\.switchName)))
        #expect(injected.text == Self.source)
    }

    @Test("leaves everything alone when the error is in a file litmus did not write")
    func foreignFile() throws {
        let injected = try Injected(Self.source)
        let before = injected.text

        let pulled = try injected.repair("/elsewhere/Other.swift:3:1: error: no such module 'Lottie'")

        #expect(pulled.isEmpty)
        #expect(injected.text == before)
    }

    @Test("reads only error lines from a build log")
    func parsesErrors() {
        let log = """
        /p/A.swift:12:5: error: cannot find 'x' in scope
        /p/B.swift:3:1: warning: unused
        note: something
        /p/C.swift:7:9: error: type mismatch
        """

        #expect(BuildRepair.errors(in: log).map(\.path) == ["/p/A.swift", "/p/C.swift"])
        #expect(BuildRepair.errors(in: log).map(\.line) == [12, 7])
    }

    @Test("reads an error line swift build coloured")
    func coloured() {
        let log = "/p/A.swift:10:75: \u{1B}[1;31merror: \u{1B}[1;39mrequires Comparable\u{1B}[0;0m"

        #expect(BuildRepair.errors(in: log).map(\.line) == [10])
    }
}
