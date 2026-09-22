import Foundation
import Testing

@testable import LitmusCore

@Suite("Coverage")
struct CoverageTests {
    private let lcov = """
    SF:/build/Sources/App/Covered.swift
    DA:10,3
    DA:11,0
    DA:12,1
    LF:3
    LH:2
    end_of_record
    SF:/build/Sources/App/Dead.swift
    DA:5,0
    DA:6,0
    LF:2
    LH:0
    end_of_record
    """

    // MARK: - reading lcov

    @Test("reads which lines ran")
    func parsesLines() {
        let coverage = Lcov.parse(lcov)

        #expect(coverage.files["/build/Sources/App/Covered.swift"]
            == .lines(covered: [10, 12], accounted: [10, 11, 12]))
    }

    /// A file where nothing ran is the case worth catching: every mutant in it
    /// survives, whatever the code says.
    @Test("marks a file with nothing running as unreached")
    func parsesDeadFile() {
        #expect(Lcov.parse(lcov).files["/build/Sources/App/Dead.swift"] == .unreached)
        #expect(Lcov.parse(lcov).deadFiles == 1)
    }

    // MARK: - deciding

    @Test("drops a mutant on a line that never ran")
    func dropsUncoveredLine() {
        let coverage = Lcov.parse(lcov)
        let file = "/build/Sources/App/Covered.swift"

        #expect(coverage.reaches(path: file, line: 10))
        #expect(!coverage.reaches(path: file, line: 11))
        #expect(coverage.reaches(path: file, line: 12))
    }

    @Test("drops every mutant in a file that never ran")
    func dropsDeadFile() {
        let coverage = Lcov.parse(lcov)

        #expect(!coverage.reaches(path: "/build/Sources/App/Dead.swift", line: 5))
        #expect(!coverage.reaches(path: "/build/Sources/App/Dead.swift", line: 999))
    }

    /// Anything the report is silent about is kept. Dropping a mutant that
    /// could have been killed hides a hole, which is the one failure this tool
    /// exists to prevent.
    @Test("keeps a mutant the report says nothing about")
    func keepsUnknown() {
        let coverage = Lcov.parse(lcov)

        #expect(coverage.reaches(path: "/build/Sources/App/Unmentioned.swift", line: 1))
        #expect(coverage.reaches(path: "/build/Sources/App/Covered.swift", line: 400))
    }

    @Test("keeps everything when there is no report")
    func keepsWithoutCoverage() {
        #expect(Coverage(files: [:]).reaches(path: "/anything.swift", line: 1))
    }

    // MARK: - rebasing onto the working copy

    /// Coverage is measured on the project and applied to a copy of it, so the
    /// paths never match end to end. Without this the lookup misses every file
    /// and nothing is filtered at all.
    @Test("matches the copy's paths to the report's")
    func rebases() {
        let coverage = Lcov.parse(lcov).rebased(onto: [
            "/tmp/copy-1234/Sources/App/Covered.swift",
            "/tmp/copy-1234/Sources/App/Dead.swift",
        ])

        #expect(!coverage.reaches(path: "/tmp/copy-1234/Sources/App/Dead.swift", line: 5))
        #expect(!coverage.reaches(path: "/tmp/copy-1234/Sources/App/Covered.swift", line: 11))
        #expect(coverage.reaches(path: "/tmp/copy-1234/Sources/App/Covered.swift", line: 10))
    }

    /// A shared file name is not a match: two modules can both hold a
    /// Configuration.swift, and pairing them would filter by the wrong file.
    @Test("does not match on the file name alone")
    func rebaseNeedsMoreThanAName() {
        let coverage = Lcov.parse("""
        SF:/build/Sources/Other/Dead.swift
        DA:5,0
        end_of_record
        """).rebased(onto: ["/tmp/copy/Sources/App/Dead.swift"])

        #expect(coverage.reaches(path: "/tmp/copy/Sources/App/Dead.swift", line: 5))
    }
}
