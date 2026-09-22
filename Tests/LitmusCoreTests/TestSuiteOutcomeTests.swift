import Testing

@testable import LitmusCore

/// A mutant is killed when the suite *fails*, so these mappings read backwards
/// at first glance. Getting one of them wrong silently moves the score.
@Suite("Test suite outcome")
struct TestSuiteOutcomeTests {
    @Test("a failing swift-testing run killed the mutant")
    func swiftTestingFailure() {
        let log = """
        ◇ Test run started.
        ✘ Test "offline streaming is not offline" failed after 0.7 seconds.
        ✘ Test run with 75 tests in 9 suites failed after 4.0 seconds with 1 issue.
        ** TEST FAILED **
        """

        #expect(TestSuiteOutcome(log: log, status: 1).verdict == .killed)
    }

    @Test("a passing swift-testing run let the mutant survive")
    func swiftTestingSuccess() {
        let log = """
        ◇ Test run started.
        ✔ Test run with 75 tests in 9 suites passed after 3.3 seconds.
        ** TEST SUCCEEDED **
        """

        #expect(TestSuiteOutcome(log: log, status: 0).verdict == .survived)
    }

    @Test("an XCTest run with failures killed the mutant")
    func xctestFailure() {
        let log = "Executed 40 tests, with 2 failures (0 unexpected) in 1.2 seconds"

        #expect(TestSuiteOutcome(log: log, status: 1).verdict == .killed)
    }

    @Test("an XCTest run with no failures let the mutant survive")
    func xctestSuccess() {
        let log = "Executed 40 tests, with 0 failures (0 unexpected) in 1.2 seconds"

        #expect(TestSuiteOutcome(log: log, status: 0).verdict == .survived)
    }

    /// The compiler rejecting a mutant is not the test suite catching it.
    /// Counting this as killed is what lets a broken tool report a flattering score.
    @Test("a mutant that failed to build is an error, not a kill")
    func buildFailureIsNotAKill() {
        let log = """
        error: cannot convert value of type 'Bool' to expected argument type 'Int'
        Testing cancelled because the build failed.
        ** TEST FAILED **
        """

        #expect(TestSuiteOutcome(log: log, status: 65).verdict == .error)
    }

    @Test("a log with nothing recognisable is an error")
    func emptyLog() {
        #expect(TestSuiteOutcome(log: "", status: 0).verdict == .error)
    }

    /// SwiftPM prints an XCTest summary for the XCTest bundle even when every
    /// test is a swift-testing test and that bundle is empty. Reading it as a
    /// pass turned a crashing mutant into a survivor: a hole reported as
    /// covered, by the tool whose only job is to find holes.
    @Test("ignores an XCTest summary that ran no tests")
    func ignoresEmptyXCTestBundle() {
        let log = """
        Test Suite 'All tests' passed at 2026-09-22 12:44:59.675.
        	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.016) seconds
        ◇ Test run started.
        ✘ Test "resolves every operator by name" recorded an issue
        Note: Some test targets reported failures:
        """

        #expect(TestSuiteOutcome(log: log, status: 1).verdict == .killed)
    }

    /// A mutant that makes the code trap kills the process before the testing
    /// library prints its summary. There is no summary to read, and the run
    /// plainly did not pass.
    @Test("a run that trapped killed the mutant")
    func crashIsAKill() {
        let log = """
        	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 seconds
        ◇ Test run started.
        Swift/ContiguousArrayBuffer.swift:695: Fatal error: Index out of range
        """

        #expect(TestSuiteOutcome(log: log, status: 134).verdict == .killed)
    }

    /// The last line of defence: no summary, no crash marker, but the process
    /// ended badly. That is not a passing run.
    @Test("a bad exit with no summary killed the mutant")
    func badExitIsAKill() {
        #expect(TestSuiteOutcome(log: "nothing useful here", status: 1).verdict == .killed)
    }

    @Test("a clean exit with no summary is an error, not a survivor")
    func cleanExitWithoutSummary() {
        #expect(TestSuiteOutcome(log: "nothing useful here", status: 0).verdict == .error)
    }
}
